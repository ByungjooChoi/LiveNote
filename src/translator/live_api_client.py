"""
Gemini Live API 클라이언트 (Native Audio Translation)

Live API를 사용하여 실시간 Speech-to-Speech Translation 수행.
jerryscy 스타일: Native Audio 모델 + System Instruction 기반 번역.

특징:
- 오디오 입력: 끊김 없이 계속 전송
- 텍스트 출력: 동시에 계속 수신
- proactive_audio: 모델이 선제적으로 응답
- 강력한 system_instruction으로 번역 전용 동작
"""

import asyncio
import time
from typing import Optional, Callable, AsyncGenerator
from datetime import datetime
from pathlib import Path
import json

from google import genai
from google.genai import types
from google.oauth2.service_account import Credentials

from src.config.secure_storage import SecureStorage
from src.config.settings_manager import settings


# =============================================================================
# 상수 정의
# =============================================================================

# Native Audio 모델 (Vertex AI용)
# GA 버전: gemini-live-2.5-flash-native-audio
# Preview 버전: gemini-live-2.5-flash-preview-native-audio-09-2025
NATIVE_AUDIO_MODEL = "gemini-live-2.5-flash-native-audio"

# S2ST 모델 (실제 작동 확인된 이름)
# 참고: S2ST는 번역 전용 - Proactive Audio, system_instruction 등 미지원
S2ST_MODEL = "gemini-2.5-flash-s2st-exp-11-2025"

# 기본 모델 (Native Audio 사용)
DEFAULT_MODEL = NATIVE_AUDIO_MODEL

# 오디오 설정 (Live API 요구사항)
LIVE_API_SAMPLE_RATE = 16000  # 16kHz
LIVE_API_CHANNELS = 1

# 로그 디렉토리
API_LOG_DIR = Path(__file__).parent.parent.parent / "logs" / "api"


# =============================================================================
# 번역 System Instruction (jerryscy 스타일)
# =============================================================================

def get_translation_system_instruction(source_lang: str = "English (en-US)",
                                         target_lang: str = "Korean (ko)") -> str:
    """
    번역 전용 System Instruction 생성.

    jerryscy/Live-translation 프로젝트 기반.
    모델이 번역만 수행하고 대화하지 않도록 강력히 제한.

    Args:
        source_lang: 원본 언어 (예: "English (en-US)")
        target_lang: 대상 언어 (예: "Korean (ko)")

    Returns:
        System instruction 문자열
    """
    return f"""**Persona:**
You are a real-time, high-fidelity audio translator. Your only function is to listen to spoken {source_lang} and immediately translate it into spoken {target_lang}.

**Core Directive:**
Translate new {source_lang} audio input into {target_lang} audio output. Your translation must be immediate, precise, and reflect the vocal delivery of the speaker.

**Rules of Operation:**

1.  **Input Language:** You will only receive audio input in `{source_lang}`.
2.  **Output Language:** You must only produce audio output in `{target_lang}`.
3.  **Real-Time Translation:** Translate only the new words and phrases you hear since your last translation. Do not wait for the speaker to finish a long sentence. Translate incrementally as the speaker talks.
4.  **Vocal Replication:** Your primary goal is to replicate the speaker's vocal characteristics in your translated speech. This includes:
    *   **Pacing and Speed:** Match the speaker's rate of speech.
    *   **Intonation and Tone:** Mirror the rise and fall of the speaker's voice, including emotional tone.
    *   **Cadence and Rhythm:** Emulate the speaker's natural speech patterns.
5.  **No Extraneous Content:**
    *   Do not add any commentary, explanations, or answers.
    *   Do not ask questions.
    *   Do not engage in conversation.
    *   If the speaker asks you a question, translate the question into `{target_lang}` and do not answer it.

**Strict Protocol Adherence:**

*   **Warning:** Any deviation from this translation-only function is a critical failure. Generating any content that is not a direct, incremental translation of the new `{source_lang}` input will result in immediate termination of the session.
*   **Important:** You are a translation conduit, not an assistant. Under no circumstances are you to generate original content. Your sole purpose is to provide a seamless and accurate real-time audio translation that preserves the vocal nuances of the original speaker.
"""


# =============================================================================
# LiveAPIClient 클래스
# =============================================================================

class LiveAPIClient:
    """
    Gemini Live API 기반 실시간 번역 클라이언트.

    jerryscy 스타일 아키텍처:
    - Native Audio 모델 + System Instruction 기반 번역
    - proactive_audio=True로 선제적 응답
    - enable_affective_dialog=False로 감정 대화 비활성화

    Full Duplex:
    - send_audio(): 오디오 청크를 Live API로 전송 (독립적)
    - receive_loop(): 텍스트 응답을 수신 (독립적)
    """

    def __init__(self, model_name: str = DEFAULT_MODEL,
                 source_lang: str = "English (en-US)",
                 target_lang: str = "Korean (ko)"):
        """
        클라이언트 초기화.

        Args:
            model_name: 모델 이름 (NATIVE_AUDIO_MODEL 또는 S2ST_MODEL)
            source_lang: 원본 언어 (예: "English (en-US)")
            target_lang: 대상 언어 (예: "Korean (ko)")
        """
        self.model_name = model_name
        self.source_lang = source_lang
        self.target_lang = target_lang

        # 클라이언트 상태
        self.client: Optional[genai.Client] = None
        self.session = None
        self._session_manager = None
        self._config = None
        self.is_connected = False
        self._running = False

        # Async tasks
        self._receive_task: Optional[asyncio.Task] = None

        # 콜백
        self.on_input_transcription: Optional[Callable[[str], None]] = None   # 원문
        self.on_output_transcription: Optional[Callable[[str], None]] = None  # 번역
        self.on_error: Optional[Callable[[str], None]] = None
        self.on_turn_complete: Optional[Callable[[], None]] = None

        # jerryscy 스타일 버퍼링: 리스트에 누적 후 주기적으로 flush
        self._input_transcription_buffer: list[str] = []
        self._output_transcription_buffer: list[str] = []
        self._flush_task: Optional[asyncio.Task] = None
        self._flush_interval = 1.0  # 1초마다 flush (S2ST fragmentation 대응)

        # 현재 텍스트 버퍼 (스트리밍 누적용) - 기존 호환성 유지
        self._current_input_text = ""
        self._current_output_text = ""

        # 통계
        self._audio_chunks_sent = 0
        self._transcriptions_received = 0
        self._start_time: Optional[float] = None

        # 로그
        self._init_log()

        print(f"[LIVE-API] Initialized for model: {self.model_name}")

    def _init_log(self) -> None:
        """로그 파일 초기화."""
        try:
            API_LOG_DIR.mkdir(parents=True, exist_ok=True)
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            self._log_file = API_LOG_DIR / f"live_api_{timestamp}.log"
            print(f"[LIVE-API] Log: {self._log_file}")
        except Exception as e:
            print(f"[LIVE-API] Log init error: {e}")
            self._log_file = None

    def _log(self, event: str, data: dict = None) -> None:
        """이벤트 로깅."""
        if not self._log_file:
            return
        try:
            entry = {
                "timestamp": datetime.now().isoformat(),
                "elapsed": time.time() - self._start_time if self._start_time else 0,
                "event": event,
                "data": data or {}
            }
            with open(self._log_file, 'a', encoding='utf-8') as f:
                f.write(json.dumps(entry, ensure_ascii=False) + '\n')
        except Exception:
            pass

    async def connect(self) -> bool:
        """
        Live API 세션 시작.

        S2ST 모델은 Vertex AI에서만 사용 가능하므로 Vertex AI SDK를 사용.
        Service Account 인증 방식 지원.

        Returns:
            연결 성공 여부
        """
        try:
            self._start_time = time.time()
            self._log("connect_start", {"model": self.model_name})

            # Vertex AI 설정 (S2ST는 Vertex AI에서만 지원)
            project_id = settings.get("translation", "vertex_project", "elastic-sa")
            location = settings.get("translation", "vertex_location", "us-central1")
            sa_key_path = settings.get("translation", "service_account_key", None)

            print(f"[LIVE-API] Using Vertex AI: project={project_id}, location={location}")

            # Service Account 인증
            if sa_key_path:
                print(f"[LIVE-API] Using Service Account: {sa_key_path}")
                scopes = ["https://www.googleapis.com/auth/cloud-platform"]
                credentials = Credentials.from_service_account_file(
                    sa_key_path,
                    scopes=scopes
                )
                self.client = genai.Client(
                    vertexai=True,
                    project=project_id,
                    location=location,
                    credentials=credentials,
                )
            else:
                # ADC (Application Default Credentials) 폴백
                print("[LIVE-API] Using ADC (Application Default Credentials)")
                self.client = genai.Client(
                    vertexai=True,
                    project=project_id,
                    location=location,
                )

            # 타겟 언어에서 언어 코드 추출 (예: "Korean (ko)" → "ko")
            target_lang_code = self.target_lang.split("(")[-1].rstrip(")").strip()
            if not target_lang_code or len(target_lang_code) > 10:
                target_lang_code = "ko"  # 기본값

            # 모델 타입에 따라 다른 설정 사용
            is_s2st = "s2st" in self.model_name.lower()
            is_native_audio = "native-audio" in self.model_name.lower()

            if is_s2st:
                # S2ST 모델: 공식 문서 예제 그대로 적용
                # https://cloud.google.com/vertex-ai/generative-ai/docs/live-api/speech-to-speech-translation
                print(f"[LIVE-API] S2ST model detected - using official example config")

                self._config = types.LiveConnectConfig(
                    response_modalities=["AUDIO"],
                    speech_config=types.SpeechConfig(
                        language_code=target_lang_code  # voice_config 없이 language_code만!
                    ),
                    input_audio_transcription=types.AudioTranscriptionConfig(),
                    output_audio_transcription=types.AudioTranscriptionConfig(),
                )
            else:
                # Native Audio 모델: jerryscy 스타일 (system_instruction 기반)
                print(f"[LIVE-API] Native Audio model detected - using jerryscy style config")
                system_instruction = get_translation_system_instruction(
                    source_lang=self.source_lang,
                    target_lang=self.target_lang
                )
                self._config = types.LiveConnectConfig(
                    response_modalities=["AUDIO"],
                    speech_config=types.SpeechConfig(
                        language_code=target_lang_code,
                        voice_config=types.VoiceConfig(
                            prebuilt_voice_config=types.PrebuiltVoiceConfig(
                                voice_name="Puck"
                            )
                        ),
                    ),
                    # jerryscy 핵심 설정
                    proactivity=types.ProactivityConfig(proactive_audio=True),
                    enable_affective_dialog=False,
                    input_audio_transcription=types.AudioTranscriptionConfig(),
                    output_audio_transcription=types.AudioTranscriptionConfig(),
                    system_instruction=types.Content(
                        parts=[types.Part(text=system_instruction)]
                    ),
                )

            print(f"[LIVE-API] Connecting to {self.model_name}...")
            print(f"[LIVE-API] Model type: {'S2ST' if is_s2st else 'Native Audio'}")
            print(f"[LIVE-API] Translation: {self.source_lang} → {self.target_lang}")

            # 세션 연결 (async context manager)
            self._session_manager = self.client.aio.live.connect(
                model=self.model_name,
                config=self._config
            )
            self.session = await self._session_manager.__aenter__()

            self.is_connected = True
            self._running = True

            # 수신 태스크 시작
            self._receive_task = asyncio.create_task(self._receive_loop())

            # 버퍼 flush 태스크 시작 (jerryscy 스타일)
            self._flush_task = asyncio.create_task(self._flush_loop())

            self._log("connected", {
                "model": self.model_name,
                "source_lang": self.source_lang,
                "target_lang": self.target_lang,
                "model_type": "s2st" if is_s2st else "native-audio"
            })
            print(f"[LIVE-API] ✓ Connected!")
            print(f"[LIVE-API]   - Model: {self.model_name}")
            print(f"[LIVE-API]   - Type: {'S2ST' if is_s2st else 'Native Audio (jerryscy)'}")
            print(f"[LIVE-API]   - Translation: {self.source_lang} → {self.target_lang}")

            return True

        except Exception as e:
            self._log("connect_error", {"error": str(e)})
            print(f"[LIVE-API] Connection error: {e}")
            import traceback
            traceback.print_exc()
            if self.on_error:
                self.on_error(f"Live API connection failed: {e}")
            return False

    async def disconnect(self) -> None:
        """세션 종료."""
        self._running = False

        # 수신 태스크 취소
        if self._receive_task:
            self._receive_task.cancel()
            try:
                await self._receive_task
            except asyncio.CancelledError:
                pass

        # Flush 태스크 취소
        if self._flush_task:
            self._flush_task.cancel()
            try:
                await self._flush_task
            except asyncio.CancelledError:
                pass

        # 세션 종료 (context manager 사용)
        if hasattr(self, '_session_manager') and self._session_manager:
            try:
                await self._session_manager.__aexit__(None, None, None)
            except Exception as e:
                print(f"[LIVE-API] Close error: {e}")

        self.session = None
        self.is_connected = False

        # 통계 출력
        elapsed = time.time() - self._start_time if self._start_time else 0
        print(f"[LIVE-API] Disconnected. Stats:")
        print(f"  - Duration: {elapsed:.1f}s")
        print(f"  - Audio chunks sent: {self._audio_chunks_sent}")
        print(f"  - Transcriptions received: {self._transcriptions_received}")

        self._log("disconnected", {
            "duration": elapsed,
            "chunks_sent": self._audio_chunks_sent,
            "transcriptions": self._transcriptions_received
        })

    async def send_audio(self, audio_data: bytes) -> bool:
        """
        오디오 데이터 전송 (Full Duplex - 입력 측).

        이 메서드는 블로킹 없이 즉시 반환됨.
        수신은 별도의 _receive_loop에서 처리.

        Args:
            audio_data: PCM 오디오 (16kHz, 16-bit, mono)

        Returns:
            전송 성공 여부
        """
        if not self.session or not self._running:
            return False

        try:
            # Live API로 오디오 전송
            await self.session.send(
                input=types.LiveClientRealtimeInput(
                    media_chunks=[
                        types.Blob(
                            data=audio_data,
                            mime_type="audio/pcm"
                        )
                    ]
                )
            )

            self._audio_chunks_sent += 1

            # 100청크마다 로그
            if self._audio_chunks_sent % 100 == 0:
                elapsed = time.time() - self._start_time if self._start_time else 0
                print(f"[LIVE-API] @{elapsed:.1f}s Sent {self._audio_chunks_sent} chunks")

            return True

        except Exception as e:
            print(f"[LIVE-API] Send error: {e}")
            self._log("send_error", {"error": str(e)})
            return False

    async def _receive_loop(self) -> None:
        """
        응답 수신 루프 (Full Duplex - 출력 측).

        send_audio()와 독립적으로 계속 실행됨.
        텍스트 transcription을 수신하여 콜백 호출.
        """
        print("[LIVE-API] Receive loop started")

        try:
            async for response in self.session.receive():
                if not self._running:
                    break

                await self._process_response(response)

        except asyncio.CancelledError:
            print("[LIVE-API] Receive loop cancelled")
        except Exception as e:
            print(f"[LIVE-API] Receive error: {e}")
            self._log("receive_error", {"error": str(e)})
            if self.on_error:
                self.on_error(f"Receive error: {e}")

    def _is_sentence_complete(self, text: str, is_korean: bool = True) -> bool:
        """
        문장이 완성되었는지 감지.

        Args:
            text: 검사할 텍스트
            is_korean: 한국어 여부

        Returns:
            문장 완성 여부
        """
        if not text:
            return False

        text = text.strip()
        if not text:
            return False

        # 공통 문장 종결 부호
        common_endings = ('.', '!', '?', '。')
        if text[-1] in common_endings:
            return True

        if is_korean:
            # 한국어 문장 종결 어미
            korean_endings = ('다.', '요.', '죠.', '까?', '니?', '네.', '야.', '지.',
                            '습니다', '입니다', '세요', '해요', '네요', '군요')
            for ending in korean_endings:
                if text.endswith(ending):
                    return True

        return False

    async def _flush_loop(self) -> None:
        """
        버퍼 flush 루프 (스마트 버퍼링).

        문장 완성 감지 + 최대 타임아웃 조합.
        - 문장이 완성되면 즉시 flush
        - 최대 2초 경과 시 강제 flush
        """
        print(f"[LIVE-API] Flush loop started (smart buffering)")

        check_interval = 0.1  # 100ms마다 체크
        max_buffer_time = 2.0  # 최대 2초
        last_input_flush = time.time()
        last_output_flush = time.time()

        try:
            while self._running:
                await asyncio.sleep(check_interval)
                now = time.time()

                # 입력 transcription flush (영어)
                if self._input_transcription_buffer and self.on_input_transcription:
                    joined_text = "".join(self._input_transcription_buffer)
                    should_flush = (
                        self._is_sentence_complete(joined_text, is_korean=False) or
                        (now - last_input_flush) >= max_buffer_time
                    )
                    if should_flush:
                        self._input_transcription_buffer.clear()
                        self.on_input_transcription(joined_text)
                        last_input_flush = now

                # 출력 transcription flush (한국어)
                if self._output_transcription_buffer and self.on_output_transcription:
                    joined_text = "".join(self._output_transcription_buffer)
                    should_flush = (
                        self._is_sentence_complete(joined_text, is_korean=True) or
                        (now - last_output_flush) >= max_buffer_time
                    )
                    if should_flush:
                        self._output_transcription_buffer.clear()
                        self.on_output_transcription(joined_text)
                        last_output_flush = now

        except asyncio.CancelledError:
            print("[LIVE-API] Flush loop cancelled")
        except Exception as e:
            print(f"[LIVE-API] Flush error: {e}")

    async def _process_response(self, response) -> None:
        """
        개별 응답 처리.

        Args:
            response: Live API 응답
        """
        if not response.server_content:
            return

        server_content = response.server_content

        # 1. 입력 텍스트 (원문 - 영어) - 버퍼에 누적
        if server_content.input_transcription:
            text = server_content.input_transcription.text
            if text:
                self._input_transcription_buffer.append(text)
                self._current_input_text = text
                self._transcriptions_received += 1
                self._log("input_transcription", {"text": text[:100]})

        # 2. 출력 텍스트 (번역 - 한국어) - 버퍼에 누적
        if server_content.output_transcription:
            text = server_content.output_transcription.text
            if text:
                self._output_transcription_buffer.append(text)
                self._current_output_text = text
                self._log("output_transcription", {"text": text[:100]})

        # 3. 턴 완료 감지
        if server_content.turn_complete:
            self._log("turn_complete", {
                "input": self._current_input_text[:50] if self._current_input_text else "",
                "output": self._current_output_text[:50] if self._current_output_text else ""
            })

            if self.on_turn_complete:
                self.on_turn_complete()

            # 버퍼 초기화
            self._current_input_text = ""
            self._current_output_text = ""

        # 4. 오디오 출력 (무시)
        # if server_content.model_turn:
        #     for part in server_content.model_turn.parts:
        #         if part.inline_data:  # 오디오 데이터
        #             pass  # 무시!

    def get_stats(self) -> dict:
        """통계 반환."""
        elapsed = time.time() - self._start_time if self._start_time else 0
        return {
            "is_connected": self.is_connected,
            "duration_sec": elapsed,
            "audio_chunks_sent": self._audio_chunks_sent,
            "transcriptions_received": self._transcriptions_received,
            "model": self.model_name
        }


# =============================================================================
# Live API Translation Pipeline (jerryscy style)
# =============================================================================

class LiveTranslationPipeline:
    """
    Live API 실시간 번역 파이프라인 (jerryscy 스타일).

    오디오 캡처 → Live API → 텍스트 출력

    특징:
    - Native Audio 모델 + System Instruction 기반 번역
    - proactive_audio로 선제적 응답
    - 세그멘테이션 불필요 (모델이 처리)
    """

    def __init__(self, client: LiveAPIClient):
        """
        파이프라인 초기화.

        Args:
            client: LiveAPIClient 인스턴스
        """
        self.client = client

        # 오디오 버퍼 (캡처 → 전송용)
        self._audio_queue: asyncio.Queue[bytes] = asyncio.Queue(maxsize=100)

        # 상태
        self._running = False
        self._send_task: Optional[asyncio.Task] = None

        # 청크 설정 (100ms 단위로 전송)
        self.chunk_duration_ms = 100
        self.chunk_size = int(LIVE_API_SAMPLE_RATE * 2 * self.chunk_duration_ms / 1000)  # 16-bit

    async def start(self) -> bool:
        """
        파이프라인 시작.

        Returns:
            시작 성공 여부
        """
        if not self.client.is_connected:
            print("[LIVE-PIPELINE] Client not connected")
            return False

        self._running = True

        # 전송 태스크 시작
        self._send_task = asyncio.create_task(self._send_loop())

        print("[LIVE-PIPELINE] Started (Full Duplex)")
        return True

    async def stop(self) -> None:
        """파이프라인 중지."""
        self._running = False

        if self._send_task:
            self._send_task.cancel()
            try:
                await self._send_task
            except asyncio.CancelledError:
                pass

        print("[LIVE-PIPELINE] Stopped")

    async def feed_audio(self, audio_data: bytes) -> None:
        """
        오디오 데이터 피드.

        AudioCapture에서 호출됨.

        Args:
            audio_data: PCM 오디오
        """
        if not self._running:
            return

        try:
            self._audio_queue.put_nowait(audio_data)
        except asyncio.QueueFull:
            # 큐 가득 차면 오래된 데이터 버림
            try:
                self._audio_queue.get_nowait()
                self._audio_queue.put_nowait(audio_data)
            except:
                pass

    async def _send_loop(self) -> None:
        """오디오 전송 루프."""
        buffer = b""

        while self._running:
            try:
                # 큐에서 오디오 가져오기
                audio = await asyncio.wait_for(
                    self._audio_queue.get(),
                    timeout=0.1
                )
                buffer += audio

                # 청크 크기에 도달하면 전송
                while len(buffer) >= self.chunk_size:
                    chunk = buffer[:self.chunk_size]
                    buffer = buffer[self.chunk_size:]
                    await self.client.send_audio(chunk)

            except asyncio.TimeoutError:
                # 타임아웃 시 버퍼에 남은 데이터 전송
                if buffer:
                    await self.client.send_audio(buffer)
                    buffer = b""
            except asyncio.CancelledError:
                break
            except Exception as e:
                print(f"[LIVE-PIPELINE] Send loop error: {e}")


# =============================================================================
# Backward Compatibility Aliases
# =============================================================================

# 기존 S2STTranslationPipeline을 사용하는 코드와의 호환성
S2STTranslationPipeline = LiveTranslationPipeline
