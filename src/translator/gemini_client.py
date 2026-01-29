"""
Gemini API 클라이언트 (streamGenerateContent 기반)

Live API를 사용하지 않고 표준 generateContent/streamGenerateContent API를 사용하여
실시간 영어-한국어 번역을 수행합니다.

Based on: Deep Research V2 - Section 3.1, 3.2
"""

import asyncio
import json
import time
import traceback
from typing import AsyncGenerator, Optional, Callable
import numpy as np

from google import genai
from google.genai import types
from datetime import datetime
from pathlib import Path

from src.config.secure_storage import SecureStorage
from src.config.settings_manager import settings
from src.audio.wav_utils import add_wav_header
from src.translator.prompts import SYSTEM_PROMPT, RESPONSE_SCHEMA, build_full_prompt
from src.translator.context_manager import ContextManager


# =============================================================================
# 상수 정의
# =============================================================================

# 모델 설정
MODEL_NAME = "gemini-2.5-flash"

# 오디오 설정
SAMPLE_RATE = 16000
BIT_DEPTH = 16
CHANNELS = 1

# Generation 설정 (thinking 비활성화)
GENERATION_CONFIG = types.GenerateContentConfig(
    temperature=0.1,  # 낮은 temperature로 일관된 번역
    response_mime_type="application/json",
    response_schema=RESPONSE_SCHEMA,
    thinking_config=types.ThinkingConfig(thinking_budget=0),  # Thinking 비활성화
)

# API 로그 디렉토리
API_LOG_DIR = Path(__file__).parent.parent.parent / "logs" / "api"


# =============================================================================
# 응답 파서
# =============================================================================

def parse_translation_response(response_text: str) -> Optional[dict]:
    """
    Gemini 응답을 파싱합니다.

    Args:
        response_text: JSON 형식의 응답 텍스트

    Returns:
        파싱된 딕셔너리 {'transcript': ..., 'translation': ..., 'is_complete': ...}
        또는 파싱 실패 시 None
    """
    try:
        # JSON 파싱
        result = json.loads(response_text.strip())

        # 필수 필드 검증
        if not all(k in result for k in ['transcript', 'translation', 'is_complete']):
            print(f"[PARSE] Missing required fields: {result.keys()}")
            return None

        return result

    except json.JSONDecodeError as e:
        print(f"[PARSE] JSON decode error: {e}")
        print(f"[PARSE] Raw response: {response_text[:200]}")
        return None
    except Exception as e:
        print(f"[PARSE] Unexpected error: {e}")
        return None


# =============================================================================
# GeminiClient 클래스
# =============================================================================

class GeminiClient:
    """
    Gemini API 클라이언트 (streamGenerateContent 기반).

    Live API 대신 표준 API를 사용하여:
    - 배치 입력 (오디오 청크)
    - 스트리밍 출력 (TTFT 최소화)

    Features:
    - streamGenerateContent로 빠른 첫 응답
    - JSON 스키마로 구조화된 출력
    - 컨텍스트 캐리오버 (최근 5턴)
    - 오디오 오버랩 지원
    """

    def __init__(self):
        """클라이언트 초기화."""
        # API 키 로드
        self.api_key = SecureStorage.get_api_key()

        # 설정 로드
        self.model_name = settings.get("translation", "model", MODEL_NAME)

        # 레거시 모델명 처리 (native-audio, s2st → gemini-2.5-flash)
        if self.model_name in ("native-audio", "s2st"):
            print(f"[GEMINI] Legacy model '{self.model_name}' → using '{MODEL_NAME}'")
            self.model_name = MODEL_NAME

        # 클라이언트 상태
        self.client: Optional[genai.Client] = None
        self.is_connected = False

        # 컨텍스트 매니저
        self.context_manager = ContextManager(
            max_turns=5,
            overlap_duration=0.5,
            sample_rate=SAMPLE_RATE
        )

        # 콜백
        self.on_transcription: Optional[Callable[[str], None]] = None
        self.on_translation: Optional[Callable[[str], None]] = None
        self.on_error: Optional[Callable[[str], None]] = None

        # 통계
        self._request_count = 0
        self._total_latency = 0.0
        self._error_count = 0

        # API 로그 파일
        self._api_log_file: Optional[Path] = None
        self._init_api_log()

        # 클라이언트 초기화
        self._init_client()

    def _init_api_log(self) -> None:
        """API 로그 파일을 초기화합니다."""
        try:
            API_LOG_DIR.mkdir(parents=True, exist_ok=True)
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            self._api_log_file = API_LOG_DIR / f"gemini_api_{timestamp}.log"
            print(f"[GEMINI] API log: {self._api_log_file}")
        except Exception as e:
            print(f"[GEMINI] Failed to init API log: {e}")
            self._api_log_file = None

    def _log_api_call(
        self,
        request_num: int,
        request_time: datetime,
        latency: float,
        audio_size: int,
        prompt_preview: str,
        response_text: str,
        response: any
    ) -> None:
        """API 호출을 상세 로그로 기록합니다."""
        if not self._api_log_file:
            return

        try:
            # 응답 메타데이터 추출
            usage_meta = {}
            if hasattr(response, 'usage_metadata') and response.usage_metadata:
                um = response.usage_metadata
                usage_meta = {
                    'prompt_tokens': getattr(um, 'prompt_token_count', None),
                    'response_tokens': getattr(um, 'candidates_token_count', None),
                    'total_tokens': getattr(um, 'total_token_count', None),
                    'thinking_tokens': getattr(um, 'thoughts_token_count', None),
                }

            # 로그 엔트리 작성
            log_entry = {
                'request_num': request_num,
                'timestamp': request_time.isoformat(),
                'latency_sec': round(latency, 3),
                'audio_bytes': audio_size,
                'audio_duration_sec': round(audio_size / (SAMPLE_RATE * 2), 2),  # 16-bit
                'prompt_preview': prompt_preview[:100],
                'response_preview': response_text[:200] if response_text else None,
                'usage': usage_meta,
                'slow': latency > 10.0,  # 10초 이상이면 slow 플래그
            }

            with open(self._api_log_file, 'a', encoding='utf-8') as f:
                f.write(json.dumps(log_entry, ensure_ascii=False) + '\n')

            # 느린 요청은 콘솔에도 경고
            if latency > 10.0:
                print(f"[GEMINI] ⚠️ SLOW REQUEST #{request_num}: {latency:.1f}s, "
                      f"thinking_tokens={usage_meta.get('thinking_tokens', 'N/A')}")

        except Exception as e:
            print(f"[GEMINI] Log error: {e}")

    def _init_client(self) -> bool:
        """
        Gemini API 클라이언트를 초기화합니다.

        Returns:
            성공 여부
        """
        if not self.api_key:
            print("[GEMINI] ERROR: No API key found.")
            print("  Set your Gemini API key in the settings.")
            return False

        try:
            self.client = genai.Client(
                api_key=self.api_key,
                http_options={"api_version": "v1beta"}  # JSON schema 지원
            )

            print(f"=== Gemini Client Configuration ===")
            print(f"  Model: {self.model_name}")
            print(f"  API Version: v1beta")
            print(f"  Sample Rate: {SAMPLE_RATE} Hz")
            print(f"  Response Format: JSON (structured)")
            print(f"  Thinking: OFF (budget=0)")
            print(f"================================")

            return True

        except Exception as e:
            print(f"[GEMINI] Failed to initialize client: {e}")
            traceback.print_exc()
            self.client = None
            return False

    async def connect(self) -> bool:
        """
        클라이언트 연결을 준비합니다.

        Returns:
            성공 여부
        """
        if not self.client:
            if not self._init_client():
                return False

        self.is_connected = True
        print("[GEMINI] Client ready")
        return True

    def disconnect(self) -> None:
        """클라이언트 연결을 종료합니다."""
        self.is_connected = False
        print(f"[GEMINI] Disconnected. Stats: {self._request_count} requests, "
              f"avg latency: {self._total_latency / max(1, self._request_count):.2f}s, "
              f"errors: {self._error_count}")

    async def translate_audio(
        self,
        audio_data: bytes,
        use_overlap: bool = True
    ) -> Optional[dict]:
        """
        오디오 청크를 번역합니다.

        Args:
            audio_data: PCM 오디오 데이터 (16kHz, 16-bit, mono)
            use_overlap: 이전 청크와 오버랩 사용 여부

        Returns:
            번역 결과 {'transcript': ..., 'translation': ..., 'is_complete': ...}
            또는 실패 시 None
        """
        if not self.client or not self.is_connected:
            print("[GEMINI] Client not connected")
            return None

        start_time = time.time()
        self._request_count += 1

        try:
            # 오버랩 적용
            if use_overlap:
                audio_with_overlap = self.context_manager.get_audio_with_overlap(audio_data)
            else:
                audio_with_overlap = audio_data

            # WAV 헤더 추가
            wav_data = add_wav_header(
                audio_with_overlap,
                sample_rate=SAMPLE_RATE,
                channels=CHANNELS,
                bit_depth=BIT_DEPTH
            )

            # 컨텍스트 프롬프트 생성
            context_history = self.context_manager.get_history()
            user_prompt = build_full_prompt(context_history)

            # API 요청 설정 (thinking 비활성화)
            api_config = types.GenerateContentConfig(
                system_instruction=SYSTEM_PROMPT,
                temperature=0.1,
                response_mime_type="application/json",
                response_schema=RESPONSE_SCHEMA,
                thinking_config=types.ThinkingConfig(thinking_budget=0),  # Thinking OFF
            )

            # API 로그 준비
            request_time = datetime.now()
            audio_size = len(wav_data)
            prompt_preview = user_prompt[:200] if user_prompt else ""

            # API 요청
            response_text = ""
            response = await asyncio.to_thread(
                self.client.models.generate_content,
                model=self.model_name,
                contents=[
                    types.Content(
                        role="user",
                        parts=[
                            types.Part(text=user_prompt),
                            types.Part(
                                inline_data=types.Blob(
                                    data=wav_data,
                                    mime_type="audio/wav"
                                )
                            )
                        ]
                    )
                ],
                config=api_config
            )

            # 응답 추출
            if response.text:
                response_text = response.text

            latency = time.time() - start_time
            self._total_latency += latency

            # API 로그 기록
            self._log_api_call(
                request_num=self._request_count,
                request_time=request_time,
                latency=latency,
                audio_size=audio_size,
                prompt_preview=prompt_preview,
                response_text=response_text,
                response=response
            )

            print(f"[GEMINI] Response in {latency:.2f}s: {response_text[:100]}...")

            # 응답 파싱
            result = parse_translation_response(response_text)

            if result:
                # 컨텍스트에 추가
                self.context_manager.add_turn(
                    transcript=result['transcript'],
                    translation=result['translation'],
                    is_complete=result['is_complete']
                )

                # 다음 청크를 위한 오버랩 저장
                self.context_manager.set_audio_overlap(audio_data)

                # 콜백 호출
                if self.on_transcription and result['transcript']:
                    self.on_transcription(result['transcript'])
                if self.on_translation and result['translation']:
                    self.on_translation(result['translation'])

            return result

        except Exception as e:
            self._error_count += 1
            error_msg = f"Translation error: {e}"
            print(f"[GEMINI] {error_msg}")
            traceback.print_exc()

            if self.on_error:
                self.on_error(error_msg)

            return None

    async def translate_audio_streaming(
        self,
        audio_data: bytes,
        use_overlap: bool = True
    ) -> AsyncGenerator[str, None]:
        """
        오디오 청크를 스트리밍으로 번역합니다.

        streamGenerateContent를 사용하여 부분 응답을 즉시 yield합니다.
        TTFT(Time To First Token)를 최소화합니다.

        Args:
            audio_data: PCM 오디오 데이터
            use_overlap: 오버랩 사용 여부

        Yields:
            부분 응답 텍스트
        """
        if not self.client or not self.is_connected:
            print("[GEMINI] Client not connected")
            return

        start_time = time.time()
        self._request_count += 1
        first_chunk = True

        try:
            # 오버랩 적용
            if use_overlap:
                audio_with_overlap = self.context_manager.get_audio_with_overlap(audio_data)
            else:
                audio_with_overlap = audio_data

            # WAV 헤더 추가
            wav_data = add_wav_header(
                audio_with_overlap,
                sample_rate=SAMPLE_RATE,
                channels=CHANNELS,
                bit_depth=BIT_DEPTH
            )

            # 컨텍스트 프롬프트 생성
            context_history = self.context_manager.get_history()
            user_prompt = build_full_prompt(context_history)

            # 스트리밍 요청
            # Note: google-genai SDK의 generate_content_stream 사용
            full_response = ""

            response_stream = self.client.models.generate_content_stream(
                model=self.model_name,
                contents=[
                    types.Content(
                        role="user",
                        parts=[
                            types.Part(text=user_prompt),
                            types.Part(
                                inline_data=types.Blob(
                                    data=wav_data,
                                    mime_type="audio/wav"
                                )
                            )
                        ]
                    )
                ],
                config=types.GenerateContentConfig(
                    system_instruction=SYSTEM_PROMPT,
                    temperature=0.1,
                    response_mime_type="application/json",
                    response_schema=RESPONSE_SCHEMA,
                )
            )

            for chunk in response_stream:
                if chunk.text:
                    if first_chunk:
                        ttft = time.time() - start_time
                        print(f"[GEMINI] TTFT: {ttft:.3f}s")
                        first_chunk = False

                    full_response += chunk.text
                    yield chunk.text

            # 전체 응답 파싱 및 컨텍스트 업데이트
            latency = time.time() - start_time
            self._total_latency += latency

            result = parse_translation_response(full_response)

            if result:
                self.context_manager.add_turn(
                    transcript=result['transcript'],
                    translation=result['translation'],
                    is_complete=result['is_complete']
                )
                self.context_manager.set_audio_overlap(audio_data)

                if self.on_transcription and result['transcript']:
                    self.on_transcription(result['transcript'])
                if self.on_translation and result['translation']:
                    self.on_translation(result['translation'])

        except Exception as e:
            self._error_count += 1
            print(f"[GEMINI] Streaming error: {e}")
            traceback.print_exc()

    def reset_context(self) -> None:
        """컨텍스트를 초기화합니다."""
        self.context_manager.reset()
        print("[GEMINI] Context reset")

    def get_stats(self) -> dict:
        """통계를 반환합니다."""
        return {
            "request_count": self._request_count,
            "error_count": self._error_count,
            "avg_latency": self._total_latency / max(1, self._request_count),
            "context_stats": self.context_manager.get_stats()
        }


# =============================================================================
# Producer-Consumer 패턴 구현
# =============================================================================

class TranslationPipeline:
    """
    오디오 캡처 → VAD 세그멘테이션 → 번역의 Producer-Consumer 파이프라인.

    asyncio Queue를 사용하여 컴포넌트 간 비동기 통신을 수행합니다.
    """

    def __init__(self, client: GeminiClient):
        """
        파이프라인 초기화.

        Args:
            client: GeminiClient 인스턴스
        """
        self.client = client

        # 세그먼트 큐 (VAD → Translator)
        self.segment_queue: asyncio.Queue[bytes] = asyncio.Queue(maxsize=10)

        # 결과 큐 (Translator → UI)
        self.result_queue: asyncio.Queue[dict] = asyncio.Queue(maxsize=20)

        # 상태
        self._running = False
        self._consumer_task: Optional[asyncio.Task] = None

        # 타이밍 분석용
        self._start_time: Optional[float] = None
        self._segments_produced = 0
        self._segments_consumed = 0
        self._produce_times: list[float] = []  # 각 세그먼트 생성 시각
        self._consume_start_times: list[float] = []  # 각 세그먼트 처리 시작 시각
        self._consume_end_times: list[float] = []  # 각 세그먼트 처리 완료 시각

    async def start(self) -> None:
        """파이프라인을 시작합니다."""
        if self._running:
            return

        self._running = True
        self._start_time = time.time()
        self._segments_produced = 0
        self._segments_consumed = 0
        self._produce_times = []
        self._consume_start_times = []
        self._consume_end_times = []

        # Consumer 태스크 시작
        self._consumer_task = asyncio.create_task(self._consume_segments())

        print("[PIPELINE] Started")

    async def stop(self) -> None:
        """파이프라인을 중지합니다."""
        self._running = False

        if self._consumer_task:
            self._consumer_task.cancel()
            try:
                await self._consumer_task
            except asyncio.CancelledError:
                pass

        # 타이밍 분석 출력
        self._print_timing_analysis()

        print("[PIPELINE] Stopped")

    def _print_timing_analysis(self) -> None:
        """Producer-Consumer 타이밍 분석을 출력합니다."""
        if not self._start_time:
            return

        elapsed = time.time() - self._start_time
        print("\n" + "="*70)
        print("PIPELINE TIMING ANALYSIS")
        print("="*70)
        print(f"Total elapsed: {elapsed:.1f}s")
        print(f"Segments produced: {self._segments_produced}")
        print(f"Segments consumed: {self._segments_consumed}")
        print(f"Queue backlog: {self._segments_produced - self._segments_consumed}")

        if self._produce_times and self._consume_end_times:
            print("\n--- Per-Segment Timeline ---")
            for i, prod_t in enumerate(self._produce_times):
                rel_prod = prod_t - self._start_time
                if i < len(self._consume_start_times):
                    rel_start = self._consume_start_times[i] - self._start_time
                    queue_wait = self._consume_start_times[i] - prod_t
                else:
                    rel_start = None
                    queue_wait = None

                if i < len(self._consume_end_times):
                    rel_end = self._consume_end_times[i] - self._start_time
                    if i < len(self._consume_start_times):
                        api_time = self._consume_end_times[i] - self._consume_start_times[i]
                    else:
                        api_time = None
                    total_delay = self._consume_end_times[i] - prod_t
                else:
                    rel_end = None
                    api_time = None
                    total_delay = None

                print(f"  Seg#{i+1}: produced@{rel_prod:.1f}s", end="")
                if rel_start is not None:
                    print(f" → start@{rel_start:.1f}s (wait:{queue_wait:.1f}s)", end="")
                if rel_end is not None:
                    print(f" → done@{rel_end:.1f}s (api:{api_time:.1f}s, total:{total_delay:.1f}s)", end="")
                print()

        print("="*70 + "\n")

    async def add_segment(self, audio_segment: bytes) -> None:
        """
        세그먼트를 큐에 추가합니다.

        Args:
            audio_segment: VAD가 감지한 오디오 세그먼트
        """
        if not self._running:
            return

        now = time.time()
        self._segments_produced += 1
        self._produce_times.append(now)

        try:
            self.segment_queue.put_nowait(audio_segment)
            elapsed = now - self._start_time if self._start_time else 0
            queue_size = self.segment_queue.qsize()
            print(f"[PIPELINE] @{elapsed:.1f}s Produced seg#{self._segments_produced}: "
                  f"{len(audio_segment)} bytes, queue={queue_size}")
        except asyncio.QueueFull:
            elapsed = now - self._start_time if self._start_time else 0
            print(f"[PIPELINE] @{elapsed:.1f}s WARNING: Queue full! Dropping seg#{self._segments_produced}")

    async def get_result(self, timeout: float = 1.0) -> Optional[dict]:
        """
        결과를 가져옵니다.

        Args:
            timeout: 대기 시간 (초)

        Returns:
            번역 결과 또는 None
        """
        try:
            return await asyncio.wait_for(
                self.result_queue.get(),
                timeout=timeout
            )
        except asyncio.TimeoutError:
            return None

    async def _consume_segments(self) -> None:
        """세그먼트를 소비하고 번역합니다."""
        while self._running:
            try:
                # 세그먼트 대기
                segment = await asyncio.wait_for(
                    self.segment_queue.get(),
                    timeout=0.5
                )

                # 소비 시작 시각 기록
                consume_start = time.time()
                self._segments_consumed += 1
                self._consume_start_times.append(consume_start)

                elapsed = consume_start - self._start_time if self._start_time else 0
                queue_size = self.segment_queue.qsize()
                print(f"[PIPELINE] @{elapsed:.1f}s Consumer started seg#{self._segments_consumed}: "
                      f"{len(segment)} bytes, queue_remaining={queue_size}")

                # 번역
                result = await self.client.translate_audio(segment)

                # 소비 완료 시각 기록
                consume_end = time.time()
                self._consume_end_times.append(consume_end)

                api_time = consume_end - consume_start
                elapsed_end = consume_end - self._start_time if self._start_time else 0
                print(f"[PIPELINE] @{elapsed_end:.1f}s Consumer finished seg#{self._segments_consumed}: "
                      f"api_time={api_time:.1f}s")

                if result:
                    # 결과 큐에 추가
                    try:
                        self.result_queue.put_nowait(result)
                    except asyncio.QueueFull:
                        # 오래된 결과 제거하고 새 결과 추가
                        self.result_queue.get_nowait()
                        self.result_queue.put_nowait(result)

            except asyncio.TimeoutError:
                continue
            except asyncio.CancelledError:
                break
            except Exception as e:
                print(f"[PIPELINE] Consumer error: {e}")
                traceback.print_exc()
