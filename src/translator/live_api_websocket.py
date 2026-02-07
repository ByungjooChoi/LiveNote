"""
Gemini Live API 클라이언트 (WebSocket 버전)

공식 문서 WebSocket 예제 기반:
https://cloud.google.com/vertex-ai/generative-ai/docs/live-api/speech-to-speech-translation

핵심: enable_speech_to_speech_translation: True 파라미터 사용
- SDK에서는 지원 안 되는 파라미터
- WebSocket 직접 연결로만 사용 가능
"""

import asyncio
import json
import base64
import time
from typing import Optional, Callable
from datetime import datetime
from pathlib import Path

import websockets
from google.oauth2.service_account import Credentials
from google.auth.transport.requests import Request

from src.config.settings_manager import settings


# =============================================================================
# 상수 정의
# =============================================================================

# S2ST 모델 (실제 작동 확인된 이름)
S2ST_MODEL = "gemini-2.5-flash-s2st-exp-11-2025"

# Vertex AI WebSocket 엔드포인트
# 형식: wss://{location}-aiplatform.googleapis.com/ws/google.cloud.aiplatform.v1beta1.LlmBidiService/BidiGenerateContent
WEBSOCKET_URL_TEMPLATE = "wss://{location}-aiplatform.googleapis.com/ws/google.cloud.aiplatform.v1beta1.LlmBidiService/BidiGenerateContent"

# 오디오 설정
LIVE_API_SAMPLE_RATE = 16000  # 16kHz input
OUTPUT_SAMPLE_RATE = 24000    # 24kHz output

# 로그 디렉토리
API_LOG_DIR = Path(__file__).parent.parent.parent / "logs" / "api"


# =============================================================================
# WebSocket 기반 S2ST 클라이언트
# =============================================================================

class LiveAPIWebSocketClient:
    """
    WebSocket 기반 Live API S2ST 클라이언트.

    공식 문서 예제 기반으로 enable_speech_to_speech_translation: True 사용.
    """

    def __init__(self, model_name: str = S2ST_MODEL,
                 source_lang: str = "English (en-US)",
                 target_lang: str = "Korean (ko)"):
        """
        클라이언트 초기화.

        Args:
            model_name: 모델 이름
            source_lang: 원본 언어
            target_lang: 대상 언어
        """
        self.model_name = model_name
        self.source_lang = source_lang
        self.target_lang = target_lang

        # WebSocket 연결
        self.ws = None
        self.is_connected = False
        self._running = False

        # Async tasks
        self._receive_task: Optional[asyncio.Task] = None

        # 콜백
        self.on_input_transcription: Optional[Callable[[str], None]] = None
        self.on_output_transcription: Optional[Callable[[str], None]] = None
        self.on_audio_output: Optional[Callable[[bytes], None]] = None
        self.on_error: Optional[Callable[[str], None]] = None
        self.on_turn_complete: Optional[Callable[[], None]] = None

        # 버퍼링 (jerryscy 스타일)
        self._input_transcription_buffer: list[str] = []
        self._output_transcription_buffer: list[str] = []
        self._flush_task: Optional[asyncio.Task] = None

        # 세션 재연결 관련
        self._session_handle: Optional[str] = None  # 세션 핸들 (재연결용)
        self._reconnect_count = 0
        self._max_reconnects = 5  # 최대 재연결 시도 횟수
        self._reconnecting = False
        self._go_away_received = False

        # 통계
        self._audio_chunks_sent = 0
        self._transcriptions_received = 0
        self._start_time: Optional[float] = None

        # 로그
        self._init_log()

        print(f"[WS-S2ST] Initialized for model: {self.model_name}")

    def _init_log(self) -> None:
        """로그 파일 초기화."""
        try:
            API_LOG_DIR.mkdir(parents=True, exist_ok=True)
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            self._log_file = API_LOG_DIR / f"ws_s2st_{timestamp}.log"
            print(f"[WS-S2ST] Log: {self._log_file}")
        except Exception as e:
            print(f"[WS-S2ST] Log init error: {e}")
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

    def _get_access_token(self) -> str:
        """Service Account에서 액세스 토큰 얻기."""
        sa_key_path = settings.get("translation", "service_account_key", None)

        if sa_key_path:
            scopes = ["https://www.googleapis.com/auth/cloud-platform"]
            credentials = Credentials.from_service_account_file(sa_key_path, scopes=scopes)
            credentials.refresh(Request())
            return credentials.token
        else:
            raise ValueError("Service Account key path not configured")

    async def connect(self) -> bool:
        """
        WebSocket 연결 시작.

        Returns:
            연결 성공 여부
        """
        try:
            self._start_time = time.time()
            self._log("connect_start", {"model": self.model_name})

            # Vertex AI 설정
            project_id = settings.get("translation", "vertex_project", "elastic-sa")
            location = settings.get("translation", "vertex_location", "us-central1")

            print(f"[WS-S2ST] Using Vertex AI: project={project_id}, location={location}")

            # 액세스 토큰 얻기
            access_token = self._get_access_token()
            print(f"[WS-S2ST] Got access token")

            # WebSocket URL 구성
            ws_url = WEBSOCKET_URL_TEMPLATE.format(location=location)
            print(f"[WS-S2ST] WebSocket URL: {ws_url}")

            # 헤더
            headers = {
                "Content-Type": "application/json",
                "Authorization": f"Bearer {access_token}",
            }

            # WebSocket 연결
            self.ws = await websockets.connect(ws_url, additional_headers=headers)
            print(f"[WS-S2ST] WebSocket connected")

            # 타겟 언어 코드 추출
            target_lang_code = self.target_lang.split("(")[-1].rstrip(")").strip()
            if not target_lang_code or len(target_lang_code) > 10:
                target_lang_code = "ko"

            # 모델 경로
            model_path = f"projects/{project_id}/locations/{location}/publishers/google/models/{self.model_name}"

            # Setup 메시지 (공식 문서 WebSocket 예제)
            setup_message = {
                "setup": {
                    "model": model_path,
                    "generation_config": {
                        "response_modalities": ["AUDIO"],
                        "speech_config": {
                            "language_code": target_lang_code,
                        },
                    },
                    "input_audio_transcription": {},
                    "output_audio_transcription": {},
                    "enable_speech_to_speech_translation": True,  # 핵심!
                }
            }

            print(f"[WS-S2ST] Sending setup with enable_speech_to_speech_translation: True")
            await self.ws.send(json.dumps(setup_message))

            # Setup 응답 받기
            raw_response = await self.ws.recv()
            setup_response = json.loads(raw_response)
            print(f"[WS-S2ST] Setup response: {setup_response}")

            # 세션 핸들 저장 (재연결용)
            if "sessionHandle" in setup_response:
                self._session_handle = setup_response["sessionHandle"]
                print(f"[WS-S2ST] Session handle saved for reconnection")

            self.is_connected = True
            self._running = True
            self._reconnect_count = 0  # 연결 성공 시 리셋

            # 수신 태스크 시작
            self._receive_task = asyncio.create_task(self._receive_loop())

            # Flush 태스크 시작
            self._flush_task = asyncio.create_task(self._flush_loop())

            self._log("connected", {
                "model": self.model_name,
                "target_lang": target_lang_code,
                "enable_s2st": True
            })

            print(f"[WS-S2ST] ✓ Connected with enable_speech_to_speech_translation!")
            print(f"[WS-S2ST]   - Model: {self.model_name}")
            print(f"[WS-S2ST]   - Translation: {self.source_lang} → {self.target_lang}")

            return True

        except Exception as e:
            self._log("connect_error", {"error": str(e)})
            print(f"[WS-S2ST] Connection error: {e}")
            import traceback
            traceback.print_exc()
            if self.on_error:
                self.on_error(f"WebSocket connection failed: {e}")
            return False

    async def disconnect(self) -> None:
        """연결 종료."""
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

        # WebSocket 닫기
        if self.ws:
            try:
                await self.ws.close(code=1000, reason="Normal closure")
            except Exception as e:
                print(f"[WS-S2ST] Close error: {e}")

        self.ws = None
        self.is_connected = False

        # 통계 출력
        elapsed = time.time() - self._start_time if self._start_time else 0
        print(f"[WS-S2ST] Disconnected. Stats:")
        print(f"  - Duration: {elapsed:.1f}s")
        print(f"  - Audio chunks sent: {self._audio_chunks_sent}")
        print(f"  - Transcriptions received: {self._transcriptions_received}")

        self._log("disconnected", {
            "duration": elapsed,
            "chunks_sent": self._audio_chunks_sent,
            "transcriptions": self._transcriptions_received
        })

    async def _schedule_reconnect(self) -> None:
        """goAway 메시지 수신 후 재연결 예약."""
        if self._reconnecting:
            return

        # goAway 후 1초 대기 후 재연결
        await asyncio.sleep(1.0)
        await self._reconnect()

    async def _reconnect(self) -> None:
        """세션 재연결."""
        if self._reconnecting:
            return

        if self._reconnect_count >= self._max_reconnects:
            print(f"[WS-S2ST] Max reconnect attempts ({self._max_reconnects}) reached")
            self._log("max_reconnects_reached", {"count": self._reconnect_count})
            if self.on_error:
                self.on_error("Maximum reconnection attempts reached")
            return

        self._reconnecting = True
        self._reconnect_count += 1
        print(f"[WS-S2ST] 🔄 Reconnecting... (attempt {self._reconnect_count}/{self._max_reconnects})")
        self._log("reconnect_start", {"attempt": self._reconnect_count})

        try:
            # 기존 연결 정리
            if self.ws:
                try:
                    await self.ws.close()
                except:
                    pass
                self.ws = None

            self.is_connected = False

            # 잠시 대기 (백오프)
            await asyncio.sleep(min(2 ** self._reconnect_count, 10))

            # 재연결
            success = await self._connect_internal()

            if success:
                print(f"[WS-S2ST] ✅ Reconnected successfully!")
                self._log("reconnect_success", {"attempt": self._reconnect_count})
                self._reconnect_count = 0  # 성공 시 카운터 리셋
                self._go_away_received = False

                # 수신 루프 재시작
                if self._receive_task:
                    self._receive_task.cancel()
                    try:
                        await self._receive_task
                    except asyncio.CancelledError:
                        pass
                self._receive_task = asyncio.create_task(self._receive_loop())

                # Flush 루프 재시작
                if self._flush_task:
                    self._flush_task.cancel()
                    try:
                        await self._flush_task
                    except asyncio.CancelledError:
                        pass
                self._flush_task = asyncio.create_task(self._flush_loop())
            else:
                print(f"[WS-S2ST] ❌ Reconnect failed")
                self._log("reconnect_failed", {"attempt": self._reconnect_count})
                # 실패 시 다시 시도
                if self._running:
                    asyncio.create_task(self._reconnect())

        except Exception as e:
            print(f"[WS-S2ST] Reconnect error: {e}")
            self._log("reconnect_error", {"error": str(e)})
        finally:
            self._reconnecting = False

    async def _connect_internal(self) -> bool:
        """내부 연결 로직 (connect에서 분리)."""
        try:
            # 액세스 토큰 갱신
            access_token = self._get_access_token()

            # Vertex AI 설정
            project_id = settings.get("translation", "vertex_project", "elastic-sa")
            location = settings.get("translation", "vertex_location", "us-central1")

            # 타겟 언어 코드 추출
            target_lang_code = self.target_lang.split("(")[-1].rstrip(")").strip()
            if not target_lang_code or len(target_lang_code) > 10:
                target_lang_code = "ko"

            # WebSocket URL
            ws_url = WEBSOCKET_URL_TEMPLATE.format(location=location)
            headers = {
                "Authorization": f"Bearer {access_token}",
                "Content-Type": "application/json",
            }

            # 모델 경로
            model_path = f"projects/{project_id}/locations/{location}/publishers/google/models/{self.model_name}"

            # Setup 메시지 구성
            setup_message = {
                "setup": {
                    "model": model_path,
                    "generation_config": {
                        "response_modalities": ["AUDIO"],
                        "speech_config": {
                            "language_code": target_lang_code,
                        },
                    },
                    "input_audio_transcription": {},
                    "output_audio_transcription": {},
                    "enable_speech_to_speech_translation": True,
                }
            }

            # 세션 핸들이 있으면 재연결에 사용
            if self._session_handle:
                setup_message["setup"]["session_resumption"] = {
                    "handle": self._session_handle
                }
                print(f"[WS-S2ST] Resuming with session handle")

            # WebSocket 연결
            self.ws = await websockets.connect(
                ws_url,
                additional_headers=headers,
                max_size=None,
                ping_interval=20,
                ping_timeout=10,
            )

            # Setup 메시지 전송
            await self.ws.send(json.dumps(setup_message))

            # Setup 응답 대기
            setup_response = await asyncio.wait_for(self.ws.recv(), timeout=30.0)
            setup_data = json.loads(setup_response)

            # 세션 핸들 저장
            if "sessionHandle" in setup_data:
                self._session_handle = setup_data["sessionHandle"]

            self.is_connected = True
            return True

        except Exception as e:
            print(f"[WS-S2ST] Internal connect error: {e}")
            return False

    async def send_audio(self, audio_data: bytes) -> bool:
        """
        오디오 데이터 전송.

        Args:
            audio_data: PCM 오디오 (16kHz, 16-bit, mono)

        Returns:
            전송 성공 여부
        """
        if not self.ws or not self._running:
            return False

        try:
            # 오디오를 base64로 인코딩
            audio_b64 = base64.b64encode(audio_data).decode('utf-8')

            # realtime_input 메시지
            msg = {
                "realtime_input": {
                    "audio": {
                        "mime_type": "audio/pcm",
                        "data": audio_b64,
                    }
                }
            }

            await self.ws.send(json.dumps(msg))
            self._audio_chunks_sent += 1

            # 100청크마다 로그
            if self._audio_chunks_sent % 100 == 0:
                elapsed = time.time() - self._start_time if self._start_time else 0
                print(f"[WS-S2ST] @{elapsed:.1f}s Sent {self._audio_chunks_sent} chunks")

            return True

        except Exception as e:
            print(f"[WS-S2ST] Send error: {e}")
            self._log("send_error", {"error": str(e)})
            return False

    async def _receive_loop(self) -> None:
        """응답 수신 루프."""
        print("[WS-S2ST] Receive loop started")

        try:
            while self._running and self.ws:
                try:
                    raw_response = await asyncio.wait_for(self.ws.recv(), timeout=30.0)
                    response = json.loads(raw_response)
                    await self._process_response(response)

                except asyncio.TimeoutError:
                    # 타임아웃은 정상 - 계속 대기
                    continue

        except asyncio.CancelledError:
            print("[WS-S2ST] Receive loop cancelled")
        except websockets.exceptions.ConnectionClosed as e:
            print(f"[WS-S2ST] Connection closed: code={e.code}, reason={e.reason}")
            self._log("connection_closed", {"code": e.code, "reason": e.reason})
            # 자동 재연결 시도 (의도적 종료가 아닌 경우)
            if self._running and not self._reconnecting:
                asyncio.create_task(self._reconnect())
        except Exception as e:
            print(f"[WS-S2ST] Receive error: {e}")
            self._log("receive_error", {"error": str(e)})
            if self.on_error:
                self.on_error(f"Receive error: {e}")
            # 예외 발생 시에도 재연결 시도
            if self._running and not self._reconnecting:
                asyncio.create_task(self._reconnect())

    async def _process_response(self, response: dict) -> None:
        """
        응답 처리.

        Args:
            response: JSON 응답
        """
        # 1. goAway 메시지 감지 (세션 종료 예고)
        go_away = response.get("goAway")
        if go_away:
            time_left = go_away.get("timeLeft", "unknown")
            print(f"[WS-S2ST] ⚠️ goAway received! Time left: {time_left}")
            self._log("go_away", {"time_left": time_left})
            self._go_away_received = True
            # 자동 재연결 트리거
            asyncio.create_task(self._schedule_reconnect())
            return

        # 2. 세션 핸들 저장 (재연결용)
        session_handle = response.get("sessionHandle")
        if session_handle:
            self._session_handle = session_handle
            print(f"[WS-S2ST] Session handle received: {session_handle[:20]}...")
            self._log("session_handle", {"handle": session_handle[:50]})

        server_content = response.get("serverContent")
        if not server_content:
            return

        # 1. 입력 텍스트 (원문)
        input_transcription = server_content.get("inputTranscription")
        if input_transcription:
            text = input_transcription.get("text")
            if text:
                self._input_transcription_buffer.append(text)
                self._transcriptions_received += 1
                self._log("input_transcription", {"text": text[:100]})

        # 2. 출력 텍스트 (번역)
        output_transcription = server_content.get("outputTranscription")
        if output_transcription:
            text = output_transcription.get("text")
            if text:
                self._output_transcription_buffer.append(text)
                self._log("output_transcription", {"text": text[:100]})

        # 3. 오디오 출력
        model_turn = server_content.get("modelTurn")
        if model_turn:
            parts = model_turn.get("parts")
            if parts:
                for part in parts:
                    inline_data = part.get("inlineData")
                    if inline_data:
                        audio_b64 = inline_data.get("data")
                        if audio_b64 and self.on_audio_output:
                            audio_bytes = base64.b64decode(audio_b64)
                            self.on_audio_output(audio_bytes)

        # 4. 턴 완료
        turn_complete = server_content.get("turnComplete")
        if turn_complete:
            self._log("turn_complete", {})
            if self.on_turn_complete:
                self.on_turn_complete()

    def _smart_join(self, fragments: list[str]) -> str:
        """
        텍스트 조각들을 스마트하게 연결.

        각 조각 사이에 필요하면 공백 추가.
        """
        if not fragments:
            return ""

        result = []
        for i, fragment in enumerate(fragments):
            if not fragment:
                continue

            if i == 0:
                result.append(fragment)
            else:
                # 이전 텍스트가 공백으로 끝나거나 현재가 공백으로 시작하면 그냥 붙임
                prev_ends_space = result and result[-1] and result[-1][-1] in ' \n\t'
                curr_starts_space = fragment[0] in ' \n\t'
                # 한국어는 공백 없이 붙여도 됨 (조사 등)
                # 영어는 공백 필요

                if prev_ends_space or curr_starts_space:
                    result.append(fragment)
                else:
                    result.append(' ' + fragment)

        return ''.join(result)

    def _is_sentence_complete(self, text: str, is_korean: bool = True) -> bool:
        """문장 완성 감지."""
        if not text:
            return False
        text = text.strip()
        if not text:
            return False

        common_endings = ('.', '!', '?', '。')
        if text[-1] in common_endings:
            return True

        if is_korean:
            korean_endings = ('다.', '요.', '죠.', '까?', '니?', '네.', '야.', '지.',
                            '습니다', '입니다', '세요', '해요', '네요', '군요')
            for ending in korean_endings:
                if text.endswith(ending):
                    return True

        return False

    async def _flush_loop(self) -> None:
        """버퍼 flush 루프 - 영어/한국어 쌍으로 출력."""
        print(f"[WS-S2ST] Flush loop started (paired output, extended buffer)")

        check_interval = 0.1
        max_buffer_time = 8.0  # 8초마다 또는 문장 완성 시 flush
        min_text_length = 20   # 최소 20자 이상일 때만 문장 완성 체크
        last_flush = time.time()

        try:
            while self._running:
                await asyncio.sleep(check_interval)
                now = time.time()

                # 둘 다 내용이 있어야 쌍으로 출력
                has_input = bool(self._input_transcription_buffer)
                has_output = bool(self._output_transcription_buffer)

                if has_input and has_output:
                    input_text = self._smart_join(self._input_transcription_buffer)
                    output_text = self._smart_join(self._output_transcription_buffer)

                    # flush 조건:
                    # 1. 충분한 길이(20자+) + 문장 완성
                    # 2. 또는 타임아웃(8초)
                    is_long_enough = len(output_text) >= min_text_length
                    is_sentence_done = is_long_enough and self._is_sentence_complete(output_text, is_korean=True)
                    is_timeout = (now - last_flush) >= max_buffer_time

                    should_flush = is_sentence_done or is_timeout

                    if should_flush:
                        # 영어 먼저, 한국어 다음 (쌍으로 출력)
                        self._input_transcription_buffer.clear()
                        self._output_transcription_buffer.clear()

                        if self.on_input_transcription:
                            self.on_input_transcription(input_text)
                        if self.on_output_transcription:
                            self.on_output_transcription(output_text)

                        last_flush = now
                        print(f"[WS-S2ST] Flushed pair: EN({len(input_text)}ch) → KO({len(output_text)}ch)")

                # 입력만 있고 출력이 없는 경우 (아직 번역 안 됨) - 타임아웃 시만 flush
                elif has_input and not has_output:
                    if (now - last_flush) >= max_buffer_time * 1.5:  # 12초
                        input_text = self._smart_join(self._input_transcription_buffer)
                        self._input_transcription_buffer.clear()
                        if self.on_input_transcription:
                            self.on_input_transcription(input_text)
                        last_flush = now

        except asyncio.CancelledError:
            print("[WS-S2ST] Flush loop cancelled")
        except Exception as e:
            print(f"[WS-S2ST] Flush error: {e}")

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
# WebSocket S2ST Pipeline
# =============================================================================

class WebSocketS2STPipeline:
    """
    WebSocket S2ST 파이프라인.

    오디오 캡처 → WebSocket → 텍스트 출력
    """

    def __init__(self, client: LiveAPIWebSocketClient):
        self.client = client
        self._audio_queue: asyncio.Queue[bytes] = asyncio.Queue(maxsize=100)
        self._running = False
        self._send_task: Optional[asyncio.Task] = None

        # 청크 설정 (100ms - Google 권장 최대치)
        # Best practice: "Send small chunks (20ms - 100ms) to minimize latency"
        self.chunk_duration_ms = 100
        self.chunk_size = int(LIVE_API_SAMPLE_RATE * 2 * self.chunk_duration_ms / 1000)  # 3200 bytes

    async def start(self) -> bool:
        """파이프라인 시작."""
        if not self.client.is_connected:
            print("[WS-PIPELINE] Client not connected")
            return False

        self._running = True
        self._send_task = asyncio.create_task(self._send_loop())
        print("[WS-PIPELINE] Started")
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
        print("[WS-PIPELINE] Stopped")

    async def feed_audio(self, audio_data: bytes) -> None:
        """오디오 데이터 피드."""
        if not self._running:
            return
        try:
            self._audio_queue.put_nowait(audio_data)
        except asyncio.QueueFull:
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
                audio = await asyncio.wait_for(
                    self._audio_queue.get(),
                    timeout=0.1
                )
                buffer += audio

                while len(buffer) >= self.chunk_size:
                    chunk = buffer[:self.chunk_size]
                    buffer = buffer[self.chunk_size:]
                    await self.client.send_audio(chunk)

            except asyncio.TimeoutError:
                if buffer:
                    await self.client.send_audio(buffer)
                    buffer = b""
            except asyncio.CancelledError:
                break
            except Exception as e:
                print(f"[WS-PIPELINE] Send loop error: {e}")


# Backward compatibility
S2STTranslationPipeline = WebSocketS2STPipeline
