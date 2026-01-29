# LiveNote V2 구현 계획서

> Deep Research 결과 기반 실시간 영한 동시통역 앱 리팩토링

## 1. 개요

### 1.1 핵심 변경사항

| 구분 | 기존 (V1) | 신규 (V2) |
|------|----------|----------|
| API | Live API (WebSocket) | **generateContent (REST)** |
| 모델 | gemini-2.5-flash-native-audio-preview | **gemini-2.5-flash** |
| 청킹 | 5초 고정 시간 기반 | **VAD 기반 + 최대 6초 제한** |
| VAD | 없음 | **Silero VAD (ONNX)** |
| 응답 | 단일 응답 대기 | **스트리밍 응답 (TTFT 개선)** |
| 오디오 포맷 | audio/pcm | **audio/wav (인메모리 헤더)** |
| 프롬프트 | 단순 STT+번역 | **Ghost Suffix + Wait-k 정책** |
| 출력 | 텍스트 파싱 | **JSON 구조화 출력** |
| 컨텍스트 | 없음 | **최근 5턴 텍스트 유지** |

### 1.2 목표 레이턴시

- **목표**: 2~4초 이내
- **허용 가능한 최대**: 7초 (강제 전송 시)

---

## 2. 아키텍처

```
┌─────────────────────────────────────────────────────────────────────┐
│                        LiveNote V2 Architecture                      │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌──────────┐    ┌──────────────┐    ┌─────────────┐               │
│  │ PyAudio  │───▶│ Silero VAD   │───▶│ asyncio.Queue │              │
│  │ Capture  │    │ (ONNX)       │    │ (Producer)  │               │
│  └──────────┘    └──────────────┘    └──────┬──────┘               │
│       │                                      │                       │
│       │ 16kHz, 16-bit, Mono                  │ Audio Chunks          │
│       │ 512 samples/frame                    │ (1.5s ~ 6s)          │
│       │                                      ▼                       │
│       │         ┌────────────────────────────────────┐              │
│       │         │         WAV Header Injection       │              │
│       │         │    (struct 모듈, 44 bytes)         │              │
│       │         └─────────────────┬──────────────────┘              │
│       │                           │                                  │
│       │                           ▼                                  │
│       │         ┌────────────────────────────────────┐              │
│       │         │     Gemini 2.5 Flash API           │              │
│       │         │   streamGenerateContent            │              │
│       │         │   + Context Carryover (5턴)        │              │
│       │         └─────────────────┬──────────────────┘              │
│       │                           │                                  │
│       │                           ▼                                  │
│       │         ┌────────────────────────────────────┐              │
│       │         │     JSON Streaming Parser          │              │
│       │         │   {transcript, translation,        │              │
│       │         │    is_complete}                    │              │
│       │         └─────────────────┬──────────────────┘              │
│       │                           │                                  │
│       │                           ▼                                  │
│       │         ┌────────────────────────────────────┐              │
│       │         │            UI Update               │              │
│       │         │   (영어 즉시, 한글 스트리밍)        │              │
│       │         └────────────────────────────────────┘              │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 3. 파라미터 정의

### 3.1 오디오 설정

| 파라미터 | 값 | 설명 |
|---------|-----|------|
| SAMPLE_RATE | 16000 Hz | 음성 인식 표준 |
| BIT_DEPTH | 16-bit | 충분한 다이내믹 레인지 |
| CHANNELS | 1 (Mono) | 스테레오 불필요 |
| FRAME_SIZE | 512 samples | Silero VAD 입력 크기 (32ms) |

### 3.2 VAD 파라미터

| 파라미터 | 값 | 프레임 수 | 설명 |
|---------|-----|----------|------|
| VAD_THRESHOLD | 0.5 | - | 음성 감지 임계값 |
| MIN_SPEECH_DURATION | 100ms | 3 frames | 노이즈 필터링 |
| MIN_CHUNK_DURATION | 1.5s | 47 frames | 최소 청크 길이 (오역 방지) |
| MAX_CHUNK_DURATION | 6.0s | 187 frames | 최대 청크 길이 |
| SILENCE_THRESHOLD | 800ms | 25 frames | 문장 종료 판단 |
| FORCE_FLUSH_TIMEOUT | 7.0s | 218 frames | 강제 전송 |
| OVERLAP_DURATION | 0.5s | 15 frames | 단어 잘림 방지 |

### 3.3 VAD 상태 머신

```
┌───────────────────────────────────────────────────────────────┐
│                      VAD State Machine                         │
├───────────────────────────────────────────────────────────────┤
│                                                                │
│   ┌──────┐  speech > 100ms   ┌───────────────┐               │
│   │ IDLE │ ─────────────────▶│ SPEECH_ACTIVE │               │
│   └──────┘                   └───────┬───────┘               │
│       ▲                              │                        │
│       │                              │ silence detected       │
│       │                              ▼                        │
│       │                      ┌─────────────┐                 │
│       │                      │ HESITATION  │                 │
│       │                      └──────┬──────┘                 │
│       │                             │                         │
│       │    ┌────────────────────────┼────────────────────┐   │
│       │    │                        │                    │   │
│       │    ▼                        ▼                    ▼   │
│       │  silence < 800ms      silence >= 800ms      > 7.0s   │
│       │  (resume speech)      (sentence end)      (timeout)  │
│       │    │                        │                    │   │
│       │    │                        ▼                    ▼   │
│       │    │                 ┌────────────┐      ┌───────────┐
│       │    │                 │ SPEECH_END │      │FORCE_FLUSH│
│       │    │                 └─────┬──────┘      └─────┬─────┘
│       │    │                       │                   │     │
│       │    │                       │ emit chunk        │     │
│       └────┴───────────────────────┴───────────────────┘     │
│                                                                │
└───────────────────────────────────────────────────────────────┘
```

---

## 4. 파일 구조

```
src/
├── audio/
│   ├── capture.py          # 기존 유지
│   ├── playback.py         # 기존 유지
│   ├── device_manager.py   # 기존 유지
│   ├── buffer_manager.py   # 삭제 또는 deprecated
│   ├── vad_segmenter.py    # 🆕 Silero VAD + 상태 머신
│   └── wav_utils.py        # 🆕 인메모리 WAV 헤더
├── translator/
│   ├── gemini_client.py    # 🔄 전면 리팩토링
│   ├── prompts.py          # 🆕 시스템 프롬프트 + JSON 스키마
│   └── context_manager.py  # 🆕 컨텍스트 캐리오버
├── ui/
│   └── main_window.py      # 🔄 스트리밍 UI 업데이트
└── config/
    └── settings_manager.py # 기존 유지
```

---

## 5. 구현 상세

### 5.1 `src/audio/wav_utils.py` (신규)

```python
"""인메모리 WAV 헤더 생성 유틸리티"""

import struct

def add_wav_header(
    pcm_data: bytes,
    sample_rate: int = 16000,
    channels: int = 1,
    bit_depth: int = 16
) -> bytes:
    """
    Raw PCM 데이터에 WAV 헤더(44 bytes)를 추가합니다.
    디스크 I/O 없이 순수 바이트 연산만 수행합니다.

    Args:
        pcm_data: Raw PCM 바이트 데이터 (16-bit signed int)
        sample_rate: 샘플 레이트 (기본 16000 Hz)
        channels: 채널 수 (기본 1, Mono)
        bit_depth: 비트 심도 (기본 16)

    Returns:
        WAV 헤더가 붙은 바이트 데이터
    """
    byte_rate = sample_rate * channels * (bit_depth // 8)
    block_align = channels * (bit_depth // 8)

    header = b'RIFF'
    header += struct.pack('<I', 36 + len(pcm_data))  # ChunkSize
    header += b'WAVEfmt '
    header += struct.pack('<I', 16)      # Subchunk1Size (PCM)
    header += struct.pack('<H', 1)       # AudioFormat (PCM = 1)
    header += struct.pack('<H', channels)
    header += struct.pack('<I', sample_rate)
    header += struct.pack('<I', byte_rate)
    header += struct.pack('<H', block_align)
    header += struct.pack('<H', bit_depth)
    header += b'data'
    header += struct.pack('<I', len(pcm_data))

    return header + pcm_data
```

### 5.2 `src/audio/vad_segmenter.py` (신규)

```python
"""Silero VAD 기반 오디오 세그멘터"""

import numpy as np
import onnxruntime
from enum import Enum, auto
from typing import Optional
from pathlib import Path


class VADState(Enum):
    IDLE = auto()
    PRE_SPEECH = auto()
    SPEECH_ACTIVE = auto()
    HESITATION = auto()


class AudioSegmenter:
    """
    Silero VAD (ONNX)를 사용한 지능형 오디오 세그멘터.

    상태 머신 기반으로 문장 경계를 감지하고,
    최적의 청크를 생성합니다.
    """

    # 오디오 파라미터
    SAMPLE_RATE = 16000
    FRAME_SIZE = 512  # 32ms per frame

    # VAD 파라미터
    THRESHOLD = 0.5

    # 프레임 단위 파라미터 (1 frame = 32ms)
    MIN_SPEECH_FRAMES = 3       # ~100ms (노이즈 필터링)
    MIN_CHUNK_FRAMES = 47       # ~1.5s (최소 청크)
    MAX_SPEECH_FRAMES = 187     # ~6.0s (최대 청크)
    SILENCE_FRAMES = 25         # ~800ms (문장 종료)
    FORCE_FLUSH_FRAMES = 218    # ~7.0s (강제 전송)
    OVERLAP_FRAMES = 15         # ~0.5s (오버랩)

    def __init__(self, model_path: Optional[str] = None):
        """
        Args:
            model_path: Silero VAD ONNX 모델 경로
        """
        if model_path is None:
            # 기본 경로: src/audio/models/silero_vad.onnx
            model_path = Path(__file__).parent / "models" / "silero_vad.onnx"

        self.session = onnxruntime.InferenceSession(str(model_path))
        self._reset_model_states()

        # 상태 머신
        self.state = VADState.IDLE
        self.buffer: list[bytes] = []
        self.speech_frames = 0
        self.silence_frames = 0

        # 오버랩용 버퍼
        self._overlap_buffer: list[bytes] = []

    def _reset_model_states(self):
        """Silero 모델 내부 상태 초기화 (h, c 벡터)"""
        self._h = np.zeros((2, 1, 64), dtype=np.float32)
        self._c = np.zeros((2, 1, 64), dtype=np.float32)

    def _get_speech_prob(self, audio_chunk: bytes) -> float:
        """VAD 확률 계산"""
        # Int16 -> Float32 정규화
        audio_int16 = np.frombuffer(audio_chunk, dtype=np.int16)
        audio_float32 = audio_int16.astype(np.float32) / 32768.0
        input_tensor = audio_float32.reshape(1, -1)

        # ONNX 추론
        ort_inputs = {
            'input': input_tensor,
            'sr': np.array([self.SAMPLE_RATE], dtype=np.int64),
            'h': self._h,
            'c': self._c
        }
        out, self._h, self._c = self.session.run(None, ort_inputs)
        return float(out[0][0])

    def process_frame(self, frame_data: bytes) -> Optional[bytes]:
        """
        512 samples (32ms) 프레임을 처리하고,
        완성된 청크가 있으면 반환합니다.

        Args:
            frame_data: 512 samples의 16-bit PCM 데이터 (1024 bytes)

        Returns:
            완성된 오디오 청크 (bytes) 또는 None
        """
        speech_prob = self._get_speech_prob(frame_data)
        is_speech = speech_prob > self.THRESHOLD

        # 상태 머신 로직
        if self.state == VADState.IDLE:
            if is_speech:
                self.state = VADState.PRE_SPEECH
                self.speech_frames = 1
                self.buffer = [frame_data]
            return None

        elif self.state == VADState.PRE_SPEECH:
            self.buffer.append(frame_data)
            if is_speech:
                self.speech_frames += 1
                if self.speech_frames >= self.MIN_SPEECH_FRAMES:
                    self.state = VADState.SPEECH_ACTIVE
            else:
                # 노이즈였음, 버퍼 클리어
                self.state = VADState.IDLE
                self.buffer = []
                self.speech_frames = 0
            return None

        elif self.state == VADState.SPEECH_ACTIVE:
            self.buffer.append(frame_data)
            self.speech_frames += 1

            if not is_speech:
                self.state = VADState.HESITATION
                self.silence_frames = 1

            # 강제 전송 체크
            if self.speech_frames >= self.FORCE_FLUSH_FRAMES:
                return self._emit_chunk(keep_overlap=True)

            return None

        elif self.state == VADState.HESITATION:
            self.buffer.append(frame_data)

            if is_speech:
                # 다시 말하기 시작
                self.state = VADState.SPEECH_ACTIVE
                self.speech_frames += self.silence_frames + 1
                self.silence_frames = 0
            else:
                self.silence_frames += 1

                if self.silence_frames >= self.SILENCE_FRAMES:
                    # 문장 종료
                    total_frames = len(self.buffer)

                    # 최소 청크 길이 체크
                    if total_frames < self.MIN_CHUNK_FRAMES:
                        # 너무 짧음, 무시
                        self._reset_state()
                        return None

                    return self._emit_chunk(keep_overlap=False)

            # 강제 전송 체크
            if len(self.buffer) >= self.FORCE_FLUSH_FRAMES:
                return self._emit_chunk(keep_overlap=True)

            return None

        return None

    def _emit_chunk(self, keep_overlap: bool) -> bytes:
        """청크 생성 및 상태 리셋"""
        full_audio = b''.join(self.buffer)

        if keep_overlap:
            # 오버랩 유지 (강제 전송 시)
            self._overlap_buffer = self.buffer[-self.OVERLAP_FRAMES:]
            self.buffer = self._overlap_buffer.copy()
            self.speech_frames = self.OVERLAP_FRAMES
            self.silence_frames = 0
            self.state = VADState.SPEECH_ACTIVE
        else:
            # 완전 리셋 (문장 종료 시)
            self._reset_state()
            self._reset_model_states()

        return full_audio

    def _reset_state(self):
        """상태 머신 리셋"""
        self.state = VADState.IDLE
        self.buffer = []
        self.speech_frames = 0
        self.silence_frames = 0

    def get_overlap_audio(self) -> bytes:
        """이전 청크의 오버랩 오디오 반환 (API 호출 시 prepend용)"""
        if self._overlap_buffer:
            return b''.join(self._overlap_buffer)
        return b''

    def flush(self) -> Optional[bytes]:
        """남은 버퍼 강제 반환 (종료 시)"""
        if len(self.buffer) >= self.MIN_CHUNK_FRAMES:
            chunk = b''.join(self.buffer)
            self._reset_state()
            return chunk
        self._reset_state()
        return None
```

### 5.3 `src/translator/prompts.py` (신규)

```python
"""시스템 프롬프트 및 JSON 스키마 정의"""

# 시스템 프롬프트 (동시통역사 페르소나)
SYSTEM_PROMPT = """You are an expert simultaneous interpreter translating English audio to Korean in real-time.

CORE RULES:

1. **Latency Priority:** Translate concisely. Do not add explanations or commentary.

2. **Incomplete Sentences:**
   - If the audio cuts off mid-sentence, DO NOT guess the ending.
   - Use Korean connecting endings (Ghost Suffixes) to indicate continuation:
     - '~하고' (and)
     - '~인데' (but/however)
     - '~해서' (so/because)
     - '~며' (while/and)
   - Example: "I went to the store and..." → "저는 가게에 갔고..." (NOT "저는 가게에 갔습니다.")

3. **Context Awareness:** Use the provided previous transcripts to maintain context and resolve pronouns.

4. **Accuracy:** Transcribe the English exactly as heard, then translate. Do not omit or add words.

OUTPUT FORMAT:
Return a JSON object with exactly these fields:
- "transcript": The English speech recognized from the audio
- "translation": The Korean translation
- "is_complete": Boolean, true if the sentence seems grammatically complete"""


# JSON 응답 스키마
RESPONSE_SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "transcript": {
            "type": "STRING",
            "description": "The English speech recognized from the audio"
        },
        "translation": {
            "type": "STRING",
            "description": "The Korean translation"
        },
        "is_complete": {
            "type": "BOOLEAN",
            "description": "True if the sentence is grammatically complete, False if it was cut off mid-sentence"
        }
    },
    "required": ["transcript", "translation", "is_complete"]
}


def build_context_prompt(context_history: list[dict], max_turns: int = 5) -> str:
    """
    컨텍스트 히스토리를 프롬프트 형식으로 변환합니다.

    Args:
        context_history: [{'en': '...', 'kr': '...', 'complete': bool}, ...]
        max_turns: 포함할 최대 턴 수

    Returns:
        프롬프트에 삽입할 컨텍스트 문자열
    """
    if not context_history:
        return "[No previous context]"

    recent = context_history[-max_turns:]
    lines = []
    for i, item in enumerate(recent, 1):
        status = "✓" if item.get('complete', True) else "..."
        lines.append(f"Turn {i} {status}:")
        lines.append(f"  EN: {item['en']}")
        lines.append(f"  KR: {item['kr']}")

    return "\n".join(lines)
```

### 5.4 `src/translator/context_manager.py` (신규)

```python
"""컨텍스트 캐리오버 관리"""

from collections import deque
from typing import Optional
from dataclasses import dataclass


@dataclass
class TranslationTurn:
    """번역 턴 데이터"""
    transcript: str      # 영어 원문
    translation: str     # 한국어 번역
    is_complete: bool    # 문장 완결 여부


class ContextManager:
    """
    번역 컨텍스트를 관리합니다.
    최근 N턴의 텍스트를 유지하여 API 호출 시 포함합니다.
    """

    def __init__(self, max_turns: int = 5):
        """
        Args:
            max_turns: 유지할 최대 턴 수
        """
        self.max_turns = max_turns
        self._history: deque[TranslationTurn] = deque(maxlen=max_turns)

        # 오디오 오버랩 버퍼 (바이트)
        self._audio_overlap: Optional[bytes] = None

    def add_turn(self, transcript: str, translation: str, is_complete: bool):
        """새 번역 턴 추가"""
        self._history.append(TranslationTurn(
            transcript=transcript,
            translation=translation,
            is_complete=is_complete
        ))

    def get_context_list(self) -> list[dict]:
        """프롬프트용 컨텍스트 리스트 반환"""
        return [
            {
                'en': turn.transcript,
                'kr': turn.translation,
                'complete': turn.is_complete
            }
            for turn in self._history
        ]

    def set_audio_overlap(self, audio_data: bytes):
        """오디오 오버랩 설정 (다음 청크 앞에 붙일 용도)"""
        self._audio_overlap = audio_data

    def get_audio_overlap(self) -> Optional[bytes]:
        """오디오 오버랩 반환 및 클리어"""
        overlap = self._audio_overlap
        self._audio_overlap = None
        return overlap

    def clear(self):
        """컨텍스트 초기화"""
        self._history.clear()
        self._audio_overlap = None

    @property
    def turn_count(self) -> int:
        """현재 저장된 턴 수"""
        return len(self._history)
```

### 5.5 `src/translator/gemini_client.py` (리팩토링)

주요 변경사항:
1. Live API 관련 코드 전체 제거
2. `gemini-2.5-flash` 모델 사용
3. `streamGenerateContent` 사용 (스트리밍 응답)
4. JSON 구조화 출력
5. 컨텍스트 캐리오버 통합

```python
"""Gemini 2.5 Flash 기반 번역 클라이언트 (V2)"""

import asyncio
import json
from typing import AsyncIterator, Optional, Callable
from google import genai
from google.genai import types

from src.config.secure_storage import SecureStorage
from src.audio.wav_utils import add_wav_header
from src.translator.prompts import SYSTEM_PROMPT, RESPONSE_SCHEMA, build_context_prompt
from src.translator.context_manager import ContextManager


# 모델 설정
MODEL_ID = "gemini-2.5-flash"


class TranslationResult:
    """번역 결과 데이터 클래스"""
    def __init__(self, transcript: str, translation: str, is_complete: bool):
        self.transcript = transcript
        self.translation = translation
        self.is_complete = is_complete


class GeminiTranslator:
    """
    Gemini 2.5 Flash를 사용한 실시간 번역기.

    특징:
    - generateContent API 사용 (Live API 아님)
    - 스트리밍 응답으로 TTFT 개선
    - JSON 구조화 출력
    - 컨텍스트 캐리오버 지원
    """

    def __init__(self):
        self.api_key = SecureStorage.get_api_key()
        self.client: Optional[genai.Client] = None
        self.context = ContextManager(max_turns=5)

        # 콜백
        self.on_transcript: Optional[Callable[[str], None]] = None
        self.on_translation: Optional[Callable[[str], None]] = None
        self.on_complete: Optional[Callable[[TranslationResult], None]] = None

        self._init_client()

    def _init_client(self):
        """클라이언트 초기화"""
        if not self.api_key:
            print("ERROR: No API key found")
            return

        self.client = genai.Client(api_key=self.api_key)
        print(f"=== Gemini Translator V2 ===")
        print(f"  Model: {MODEL_ID}")
        print(f"  API: generateContent (streaming)")
        print(f"================================")

    async def translate_audio(
        self,
        audio_data: bytes,
        prepend_overlap: Optional[bytes] = None
    ) -> AsyncIterator[TranslationResult]:
        """
        오디오 청크를 번역합니다.

        Args:
            audio_data: PCM 오디오 데이터 (16kHz, 16-bit, mono)
            prepend_overlap: 앞에 붙일 오버랩 오디오 (옵션)

        Yields:
            TranslationResult (스트리밍)
        """
        if not self.client:
            return

        # 오버랩 결합
        if prepend_overlap:
            audio_data = prepend_overlap + audio_data

        # WAV 헤더 부착
        wav_data = add_wav_header(audio_data)

        # 컨텍스트 구성
        context_text = build_context_prompt(self.context.get_context_list())

        prompt = f"""[Previous Context]
{context_text}

[Instruction]
Translate the attached audio chunk. Follow all CORE RULES in the system instruction."""

        try:
            # 스트리밍 API 호출
            response = await self.client.aio.models.generate_content_stream(
                model=MODEL_ID,
                contents=[
                    types.Content(
                        parts=[
                            types.Part.from_bytes(data=wav_data, mime_type="audio/wav"),
                            types.Part.from_text(text=prompt)
                        ]
                    )
                ],
                config=types.GenerateContentConfig(
                    system_instruction=SYSTEM_PROMPT,
                    response_mime_type="application/json",
                    response_schema=RESPONSE_SCHEMA
                )
            )

            # 스트리밍 응답 처리
            full_text = ""
            async for chunk in response:
                if chunk.text:
                    full_text += chunk.text

            # JSON 파싱
            result = json.loads(full_text)
            transcript = result.get("transcript", "")
            translation = result.get("translation", "")
            is_complete = result.get("is_complete", True)

            # 콜백 호출
            if self.on_transcript and transcript:
                self.on_transcript(transcript)
            if self.on_translation and translation:
                self.on_translation(translation)

            # 컨텍스트 업데이트
            if transcript:
                self.context.add_turn(transcript, translation, is_complete)

            # 결과 반환
            result_obj = TranslationResult(transcript, translation, is_complete)
            if self.on_complete:
                self.on_complete(result_obj)
            yield result_obj

        except json.JSONDecodeError as e:
            print(f"[ERROR] JSON parsing failed: {e}")
            print(f"  Raw response: {full_text[:200]}...")
        except Exception as e:
            print(f"[ERROR] API call failed: {e}")

    def clear_context(self):
        """컨텍스트 초기화"""
        self.context.clear()
```

---

## 6. 통합 파이프라인

### 6.1 메인 루프 구조

```python
async def main():
    # 1. 컴포넌트 초기화
    translator = GeminiTranslator()
    segmenter = AudioSegmenter()
    queue = asyncio.Queue()

    # 2. Producer Task (오디오 캡처 + VAD)
    async def audio_producer():
        stream = open_pyaudio_stream()
        while running:
            frame = await asyncio.to_thread(stream.read, 512)
            chunk = segmenter.process_frame(frame)
            if chunk:
                await queue.put(chunk)

    # 3. Consumer Task (API 호출)
    async def translation_consumer():
        while running:
            chunk = await queue.get()
            overlap = segmenter.get_overlap_audio()
            async for result in translator.translate_audio(chunk, overlap):
                update_ui(result)
            queue.task_done()

    # 4. 병렬 실행
    await asyncio.gather(
        audio_producer(),
        translation_consumer()
    )
```

---

## 7. 의존성

### 7.1 새로 필요한 패키지

```
onnxruntime>=1.16.0  # Silero VAD 실행
```

### 7.2 Silero VAD 모델 다운로드

```bash
# 모델 파일 위치: src/audio/models/silero_vad.onnx
mkdir -p src/audio/models
wget https://github.com/snakers4/silero-vad/raw/master/files/silero_vad.onnx \
    -O src/audio/models/silero_vad.onnx
```

---

## 8. 구현 순서

| 순서 | 작업 | 파일 | 예상 시간 |
|-----|------|------|----------|
| 1 | WAV 헤더 유틸리티 | `wav_utils.py` | 10분 |
| 2 | 프롬프트 및 스키마 | `prompts.py` | 15분 |
| 3 | 컨텍스트 매니저 | `context_manager.py` | 15분 |
| 4 | VAD 세그멘터 | `vad_segmenter.py` | 30분 |
| 5 | Gemini 클라이언트 리팩토링 | `gemini_client.py` | 45분 |
| 6 | 메인 윈도우 통합 | `main_window.py` | 30분 |
| 7 | 테스트 및 튜닝 | - | 60분 |

**총 예상 시간: ~3.5시간**

---

## 9. 테스트 계획

### 9.1 단위 테스트

1. **WAV 헤더 생성**: 44바이트 헤더 검증
2. **VAD 상태 전이**: 각 상태 전이 로직 검증
3. **컨텍스트 관리**: 턴 추가/조회/삭제 검증
4. **JSON 파싱**: 응답 스키마 준수 검증

### 9.2 통합 테스트

1. **엔드투엔드 레이턴시**: 2~4초 이내 확인
2. **청크 경계**: 문장이 자연스럽게 나뉘는지 확인
3. **Ghost Suffix**: 불완전 문장에 연결어미 적용 확인
4. **컨텍스트 연속성**: 대명사 해결 확인

---

*작성일: 2026-01-28*
*버전: 2.0*
