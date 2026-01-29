"""
Silero VAD 기반 오디오 세그멘터

상태 머신을 사용하여 음성 구간을 지능적으로 감지하고
최적의 청크 경계에서 세그먼트합니다.

Based on: Deep Research - Section 4.1, 4.2, 4.3
"""

import asyncio
import time
from collections import deque
from enum import Enum, auto
from pathlib import Path
from typing import Callable, Optional
import numpy as np

try:
    import onnxruntime as ort
    ONNX_AVAILABLE = True
except ImportError:
    ONNX_AVAILABLE = False
    print("[VAD] WARNING: onnxruntime not installed. VAD disabled.")


# 기본 모델 경로 (프로젝트 루트 기준)
DEFAULT_MODEL_PATH = Path(__file__).parent.parent.parent / "models" / "silero_vad.onnx"


def get_default_model_path() -> Optional[str]:
    """기본 모델 경로를 반환합니다."""
    if DEFAULT_MODEL_PATH.exists():
        return str(DEFAULT_MODEL_PATH)

    # 대체 경로들 확인
    alt_paths = [
        Path.home() / ".cache" / "silero-vad" / "silero_vad.onnx",
        Path("/usr/share/silero-vad/silero_vad.onnx"),
    ]

    for path in alt_paths:
        if path.exists():
            return str(path)

    return None


class VADState(Enum):
    """VAD 상태 머신 상태."""
    IDLE = auto()           # 무음 상태
    PRE_SPEECH = auto()     # 음성 감지 대기 (버퍼링)
    SPEECH_ACTIVE = auto()  # 음성 진행 중
    HESITATION = auto()     # 짧은 침묵 (망설임)
    SPEECH_END = auto()     # 음성 종료 감지
    FORCE_FLUSH = auto()    # 강제 플러시


class SileroVADSegmenter:
    """
    Silero VAD ONNX 모델을 사용한 지능형 오디오 세그멘터.

    상태 머신:
    IDLE → PRE_SPEECH → SPEECH_ACTIVE ↔ HESITATION → SPEECH_END/FORCE_FLUSH

    Key Parameters (from Deep Research):
    - FRAME_SIZE: 512 samples (32ms @ 16kHz)
    - VAD_THRESHOLD: 0.5
    - MIN_CHUNK: 1.5s (47 frames)
    - MAX_CHUNK: 6.0s (187 frames)
    - FORCE_FLUSH: 7.0s (218 frames)
    - SILENCE_THRESHOLD: 800ms (25 frames)
    """

    # 오디오 파라미터
    SAMPLE_RATE = 16000
    FRAME_SIZE = 512  # 32ms @ 16kHz

    # VAD 파라미터
    VAD_THRESHOLD = 0.5
    PRE_SPEECH_FRAMES = 3  # 음성 시작 전 버퍼링할 프레임 수

    # 청크 길이 파라미터 (프레임 단위)
    # Deep Research 원래 설계값 (Section 3.2)
    MIN_CHUNK_FRAMES = 47    # 1.5s - 오역 방지를 위한 최소 길이
    MAX_CHUNK_FRAMES = 187   # 6.0s - 최대 청크 길이
    FORCE_FLUSH_FRAMES = 218 # 7.0s - 강제 전송 타임아웃
    SILENCE_FRAMES = 25      # 800ms - 문장 종료 판단 기준

    # 시간 변환 (참고용)
    FRAME_DURATION_MS = FRAME_SIZE / SAMPLE_RATE * 1000  # 32ms

    def __init__(
        self,
        model_path: Optional[str] = None,
        on_segment_ready: Optional[Callable[[bytes], None]] = None
    ):
        """
        VAD 세그멘터 초기화.

        Args:
            model_path: Silero VAD ONNX 모델 경로 (None이면 기본 경로 자동 탐색)
            on_segment_ready: 세그먼트 준비 시 호출할 콜백
        """
        self.on_segment_ready = on_segment_ready

        # 모델 경로 자동 탐색
        if model_path is None:
            model_path = get_default_model_path()

        # 상태 머신
        self._state = VADState.IDLE
        self._state_start_time = time.time()

        # 프레임 버퍼
        self._frame_buffer: deque[bytes] = deque()
        self._pre_speech_buffer: deque[bytes] = deque(maxlen=self.PRE_SPEECH_FRAMES)

        # 프레임 카운터
        self._speech_frames = 0       # 현재 음성 구간의 프레임 수
        self._silence_frames = 0      # 연속 무음 프레임 수
        self._total_frames = 0        # 전체 프레임 수

        # ONNX 모델
        self._session: Optional[ort.InferenceSession] = None
        self._h: Optional[np.ndarray] = None  # LSTM hidden state
        self._c: Optional[np.ndarray] = None  # LSTM cell state

        # 통계
        self._segments_created = 0
        self._force_flushes = 0

        # 모델 로드
        if ONNX_AVAILABLE and model_path:
            self._load_model(model_path)

    def _load_model(self, model_path: str) -> bool:
        """
        Silero VAD ONNX 모델을 로드합니다.

        Args:
            model_path: 모델 파일 경로

        Returns:
            성공 여부
        """
        try:
            # ONNX 런타임 세션 생성 (CPU 최적화)
            sess_options = ort.SessionOptions()
            sess_options.intra_op_num_threads = 1
            sess_options.inter_op_num_threads = 1

            self._session = ort.InferenceSession(
                model_path,
                sess_options,
                providers=['CPUExecutionProvider']
            )

            # LSTM 상태 초기화
            self._reset_states()

            print(f"[VAD] Model loaded: {model_path}")
            return True

        except Exception as e:
            print(f"[VAD] Failed to load model: {e}")
            self._session = None
            return False

    def _reset_states(self) -> None:
        """LSTM 상태를 초기화합니다."""
        # Silero VAD v4 형식: h, c 분리
        self._h = np.zeros((2, 1, 64), dtype=np.float32)
        self._c = np.zeros((2, 1, 64), dtype=np.float32)

        # Silero VAD v5 형식: state 통합 (변수명 충돌 방지: _lstm_state)
        self._lstm_state = np.zeros((2, 1, 128), dtype=np.float32)

        # Context 버퍼 (공식 구현에 맞춤)
        # 16kHz: context_size=64, 8kHz: context_size=32
        self._context = np.zeros((1, 0), dtype=np.float32)  # 빈 context로 시작

    def _run_vad(self, audio_frame: np.ndarray) -> float:
        """
        VAD 모델을 실행하여 음성 확률을 반환합니다.

        Args:
            audio_frame: 오디오 프레임 (512 samples, float32, normalized)

        Returns:
            음성 확률 (0.0 ~ 1.0)
        """
        if self._session is None:
            return 0.5  # 모델 없으면 항상 음성으로 처리 (세그먼트 생성됨)

        try:
            # 입력 준비 (공식 Silero VAD 구현에 맞춤)
            audio_input = audio_frame.reshape(1, -1).astype(np.float32)

            # Context를 입력에 붙임 (공식 구현: x = torch.cat([self._context, x], dim=1))
            context_size = 64 if self.SAMPLE_RATE == 16000 else 32
            if self._context.shape[1] == 0:
                # 초기화: context를 0으로 채움
                self._context = np.zeros((1, context_size), dtype=np.float32)

            x_with_context = np.concatenate([self._context, audio_input], axis=1)

            # Silero VAD v4/v5 입력 형식 확인
            input_names = [inp.name for inp in self._session.get_inputs()]

            if 'state' in input_names:
                # v5 형식: state 단일 입력
                # sr은 스칼라 형태로 전달 (공식 구현: np.array(sr, dtype='int64'))
                ort_inputs = {
                    'input': x_with_context,
                    'state': self._lstm_state,
                    'sr': np.array(self.SAMPLE_RATE, dtype=np.int64)
                }
                ort_outputs = self._session.run(None, ort_inputs)
                prob = ort_outputs[0].item()
                self._lstm_state = ort_outputs[1]
            else:
                # v4 형식: h, c 분리 입력
                ort_inputs = {
                    'input': x_with_context,
                    'sr': np.array(self.SAMPLE_RATE, dtype=np.int64),
                    'h': self._h,
                    'c': self._c
                }
                ort_outputs = self._session.run(None, ort_inputs)
                prob = ort_outputs[0].item()
                self._h = ort_outputs[1]
                self._c = ort_outputs[2]

            # Context 업데이트 (마지막 context_size 샘플 저장)
            self._context = audio_input[:, -context_size:]

            return prob

        except Exception as e:
            if not hasattr(self, '_error_logged'):
                print(f"[VAD] Inference error: {e}")
                self._error_logged = True
            return 0.5  # 에러 시 음성으로 처리

    def _bytes_to_float(self, audio_bytes: bytes) -> np.ndarray:
        """
        16-bit PCM 바이트를 float32 배열로 변환합니다.

        Args:
            audio_bytes: 16-bit signed int, little-endian

        Returns:
            Normalized float32 array (-1.0 ~ 1.0)
        """
        audio_int16 = np.frombuffer(audio_bytes, dtype=np.int16)
        return audio_int16.astype(np.float32) / 32768.0

    def _transition_to(self, new_state: VADState) -> None:
        """상태 전이를 수행합니다."""
        if self._state != new_state:
            old_state = self._state
            self._state = new_state
            self._state_start_time = time.time()
            print(f"[VAD] State: {old_state.name} → {new_state.name}")

    def process_frame(self, frame_bytes: bytes) -> Optional[bytes]:
        """
        단일 오디오 프레임(512 samples)을 처리합니다.

        Args:
            frame_bytes: 16-bit PCM 오디오 프레임 (1024 bytes)

        Returns:
            세그먼트가 준비되면 해당 오디오 bytes, 아니면 None
        """
        self._total_frames += 1

        # VAD 실행
        audio_float = self._bytes_to_float(frame_bytes)
        speech_prob = self._run_vad(audio_float)
        is_speech = speech_prob >= self.VAD_THRESHOLD

        # 디버그: 매 100프레임마다 VAD 확률 로깅
        if self._total_frames % 100 == 0:
            rms = np.sqrt(np.mean(audio_float ** 2))
            print(f"[VAD] Frame {self._total_frames}: prob={speech_prob:.3f}, rms={rms:.4f}, len={len(audio_float)}")

        # 상태 머신 처리
        segment = None

        if self._state == VADState.IDLE:
            segment = self._handle_idle(frame_bytes, is_speech)

        elif self._state == VADState.PRE_SPEECH:
            segment = self._handle_pre_speech(frame_bytes, is_speech)

        elif self._state == VADState.SPEECH_ACTIVE:
            segment = self._handle_speech_active(frame_bytes, is_speech)

        elif self._state == VADState.HESITATION:
            segment = self._handle_hesitation(frame_bytes, is_speech)

        # 콜백 호출
        if segment and self.on_segment_ready:
            self.on_segment_ready(segment)

        return segment

    def _handle_idle(self, frame_bytes: bytes, is_speech: bool) -> Optional[bytes]:
        """IDLE 상태 처리."""
        # Pre-speech 버퍼에 저장 (항상)
        self._pre_speech_buffer.append(frame_bytes)

        if is_speech:
            self._transition_to(VADState.PRE_SPEECH)
            # Pre-speech 버퍼의 내용을 메인 버퍼로 이동
            self._frame_buffer.extend(self._pre_speech_buffer)
            self._speech_frames = len(self._frame_buffer)

        return None

    def _handle_pre_speech(self, frame_bytes: bytes, is_speech: bool) -> Optional[bytes]:
        """PRE_SPEECH 상태 처리."""
        self._frame_buffer.append(frame_bytes)
        self._speech_frames += 1

        if is_speech:
            # 연속 음성이면 SPEECH_ACTIVE로 전이
            self._silence_frames = 0
            self._transition_to(VADState.SPEECH_ACTIVE)
        else:
            self._silence_frames += 1
            # 짧은 무음이 계속되면 다시 IDLE로
            if self._silence_frames >= self.SILENCE_FRAMES:
                self._transition_to(VADState.IDLE)
                self._frame_buffer.clear()
                self._speech_frames = 0
                self._silence_frames = 0

        return None

    def _handle_speech_active(self, frame_bytes: bytes, is_speech: bool) -> Optional[bytes]:
        """SPEECH_ACTIVE 상태 처리."""
        self._frame_buffer.append(frame_bytes)
        self._speech_frames += 1

        # 강제 플러시 체크 (7.0s)
        if self._speech_frames >= self.FORCE_FLUSH_FRAMES:
            self._force_flushes += 1
            print(f"[VAD] Force flush at {self._speech_frames} frames")
            return self._flush_segment()

        if is_speech:
            self._silence_frames = 0
        else:
            self._silence_frames += 1

            # 최소 길이 도달 + 충분한 무음 → 세그먼트 종료
            if (self._speech_frames >= self.MIN_CHUNK_FRAMES and
                self._silence_frames >= self.SILENCE_FRAMES):
                return self._flush_segment()

            # MAX_CHUNK 도달 → 세그먼트 종료
            if self._speech_frames >= self.MAX_CHUNK_FRAMES:
                print(f"[VAD] Max chunk reached at {self._speech_frames} frames")
                return self._flush_segment()

            # 짧은 무음 → HESITATION으로 전이
            if self._silence_frames >= 5:  # ~160ms
                self._transition_to(VADState.HESITATION)

        return None

    def _handle_hesitation(self, frame_bytes: bytes, is_speech: bool) -> Optional[bytes]:
        """HESITATION 상태 처리."""
        self._frame_buffer.append(frame_bytes)
        self._speech_frames += 1

        # 강제 플러시 체크
        if self._speech_frames >= self.FORCE_FLUSH_FRAMES:
            self._force_flushes += 1
            return self._flush_segment()

        if is_speech:
            # 음성 재개 → SPEECH_ACTIVE로 복귀
            self._silence_frames = 0
            self._transition_to(VADState.SPEECH_ACTIVE)
        else:
            self._silence_frames += 1

            # 충분한 무음 → 세그먼트 종료
            if self._silence_frames >= self.SILENCE_FRAMES:
                if self._speech_frames >= self.MIN_CHUNK_FRAMES:
                    return self._flush_segment()
                else:
                    # 최소 길이 미달이면 계속 대기
                    pass

        return None

    def _flush_segment(self) -> bytes:
        """
        현재 버퍼를 세그먼트로 플러시합니다.

        Returns:
            세그먼트 오디오 데이터
        """
        # 버퍼 내용 합치기
        segment_data = b''.join(self._frame_buffer)

        self._segments_created += 1
        duration_ms = len(self._frame_buffer) * self.FRAME_DURATION_MS
        print(f"[VAD] Segment #{self._segments_created}: {len(segment_data)} bytes "
              f"({duration_ms:.0f}ms, {self._speech_frames} frames)")

        # 상태 초기화
        self._frame_buffer.clear()
        self._speech_frames = 0
        self._silence_frames = 0
        self._transition_to(VADState.IDLE)

        return segment_data

    def force_flush(self) -> Optional[bytes]:
        """
        현재 버퍼를 강제로 플러시합니다.

        Returns:
            세그먼트 데이터 (버퍼가 비어있으면 None)
        """
        if not self._frame_buffer:
            return None

        self._force_flushes += 1
        return self._flush_segment()

    def reset(self) -> None:
        """세그멘터를 완전히 초기화합니다."""
        self._state = VADState.IDLE
        self._state_start_time = time.time()
        self._frame_buffer.clear()
        self._pre_speech_buffer.clear()
        self._speech_frames = 0
        self._silence_frames = 0
        self._total_frames = 0
        self._segments_created = 0
        self._force_flushes = 0

        if self._session:
            self._reset_states()

        print("[VAD] Reset complete")

    def get_stats(self) -> dict:
        """통계를 반환합니다."""
        return {
            "state": self._state.name,
            "total_frames": self._total_frames,
            "speech_frames": self._speech_frames,
            "silence_frames": self._silence_frames,
            "buffer_frames": len(self._frame_buffer),
            "segments_created": self._segments_created,
            "force_flushes": self._force_flushes,
            "model_loaded": self._session is not None
        }


class SimpleTimeBasedSegmenter:
    """
    VAD 없이 단순 시간 기반 세그멘터.

    Silero VAD 모델이 없을 때 폴백으로 사용합니다.
    """

    SAMPLE_RATE = 16000
    DEFAULT_CHUNK_DURATION = 5.0  # 5초

    def __init__(
        self,
        chunk_duration: float = DEFAULT_CHUNK_DURATION,
        on_segment_ready: Optional[Callable[[bytes], None]] = None
    ):
        """
        시간 기반 세그멘터 초기화.

        Args:
            chunk_duration: 청크 길이 (초)
            on_segment_ready: 세그먼트 준비 시 콜백
        """
        self.chunk_duration = chunk_duration
        self.on_segment_ready = on_segment_ready

        # 바이트 단위 청크 크기 (16-bit = 2 bytes)
        self.chunk_bytes = int(self.SAMPLE_RATE * chunk_duration * 2)

        self._buffer = bytearray()
        self._segments_created = 0
        self._start_time: Optional[float] = None

    def add_audio(self, audio_bytes: bytes) -> Optional[bytes]:
        """
        오디오 데이터를 추가합니다.

        Args:
            audio_bytes: 오디오 데이터

        Returns:
            청크가 완성되면 해당 데이터, 아니면 None
        """
        if self._start_time is None:
            self._start_time = time.time()

        self._buffer.extend(audio_bytes)

        # 청크 크기 도달 또는 시간 초과
        elapsed = time.time() - self._start_time
        if len(self._buffer) >= self.chunk_bytes or elapsed >= self.chunk_duration:
            return self._flush()

        return None

    def _flush(self) -> bytes:
        """버퍼를 플러시합니다."""
        segment = bytes(self._buffer)
        self._buffer.clear()
        self._start_time = None
        self._segments_created += 1

        print(f"[SIMPLE] Segment #{self._segments_created}: {len(segment)} bytes")

        if self.on_segment_ready:
            self.on_segment_ready(segment)

        return segment

    def force_flush(self) -> Optional[bytes]:
        """강제 플러시합니다."""
        if self._buffer:
            return self._flush()
        return None

    def reset(self) -> None:
        """초기화합니다."""
        self._buffer.clear()
        self._start_time = None
        self._segments_created = 0

    def get_stats(self) -> dict:
        """통계를 반환합니다."""
        return {
            "state": "TIME_BASED",
            "buffer_bytes": len(self._buffer),
            "segments_created": self._segments_created,
            "chunk_bytes": self.chunk_bytes
        }
