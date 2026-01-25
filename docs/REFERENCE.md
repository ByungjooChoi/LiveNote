# 📚 Gemini Live API Reference Documentation

이 문서는 LiveNote 프로젝트에서 사용하는 Google Gemini Live API의 핵심 참고 자료입니다.

---

## 📖 공식 문서 링크

### 1. Live API 시작하기 (Get Started)
- **URL**: https://ai.google.dev/gemini-api/docs/live
- **내용**: Live API 기본 개념, 연결 방식, 마이크 스트리밍 예제

### 2. Live API 기능 가이드 (Capabilities Guide) ⭐ 필독!
- **URL**: https://ai.google.dev/gemini-api/docs/live-guide
- **내용**: 오디오 형식, VAD, 전사, Thinking 설정 등 상세 가이드

### 3. Vertex AI - Gemini 2.5 Flash Live API
- **URL**: https://docs.cloud.google.com/vertex-ai/generative-ai/docs/models/gemini/2-5-flash-live-api
- **내용**: Vertex AI에서의 Live API 사용법 (Google Cloud)

### 4. Gemini 2.5 Native Audio 모델
- **URL**: https://ai.google.dev/gemini-api/docs/models#gemini-2.5-flash-native-audio-preview
- **모델명**: `gemini-2.5-flash-native-audio-preview-12-2025`
- **특징**: 음성 입력 → 텍스트 + 음성 출력 동시 지원

### 5. Python SDK (google-genai)
- **URL**: https://ai.google.dev/gemini-api/docs/sdks
- **패키지**: `pip install google-genai>=1.43.0`
- **참고**: `google-generativeai`와 다름! (새 SDK)

---

## 🔧 핵심 API 사용법

### 연결 설정

```python
from google import genai
from google.genai import types

# v1alpha 버전 사용 필수 (Live API 기능)
client = genai.Client(
    api_key="YOUR_API_KEY",
    http_options={"api_version": "v1alpha"}
)

config = types.LiveConnectConfig(
    response_modalities=["AUDIO"],  # Native Audio 모델 필수!
    speech_config=types.SpeechConfig(
        voice_config=types.VoiceConfig(
            prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Kore")
        )
    ),
    # ⭐ Thinking 비활성화 (더 빠른 응답)
    thinking_config=types.ThinkingConfig(
        thinking_budget=0  # 0으로 설정하면 내부 추론 비활성화
    ),
    # 중요: 오디오 출력의 텍스트 전사 활성화 (자막 표시용)
    output_audio_transcription=types.AudioTranscriptionConfig(),
    # 선택: 입력 오디오 전사 (디버깅용)
    input_audio_transcription=types.AudioTranscriptionConfig(),
    # ⭐ 자동 VAD (음성 활동 감지) - 동시통역 모드
    realtime_input_config=types.RealtimeInputConfig(
        automatic_activity_detection=types.AutomaticActivityDetection(
            disabled=False,
        )
    ),
    system_instruction=types.Content(
        parts=[types.Part(text="You are a Korean translator...")]
    ),
)
```

### 세션 시작

```python
async with client.aio.live.connect(
    model="gemini-2.5-flash-native-audio-preview-12-2025",
    config=config
) as session:
    # 오디오 전송 및 응답 수신
```

### ⭐ 오디오 전송 (올바른 방법)

```python
# ✅ 올바른 방법: audio= 파라미터 + 샘플레이트 명시!
await session.send_realtime_input(
    audio=types.Blob(data=audio_bytes, mime_type="audio/pcm;rate=16000")
)

# ❌ 잘못된 방법 1: media= 파라미터 사용
await session.send_realtime_input(
    media=types.Blob(data=audio_bytes, mime_type="audio/pcm")  # 오류!
)

# ❌ 잘못된 방법 2: 샘플레이트 누락
await session.send_realtime_input(
    audio=types.Blob(data=audio_bytes, mime_type="audio/pcm")  # rate 누락!
)
```

### 오디오 스트림 일시 중지

```python
# 오디오 스트림이 1초 이상 일시중지되면 audioStreamEnd 전송 권장
await session.send_realtime_input(audio_stream_end=True)
```

### 응답 트리거 (수동 VAD 모드)

```python
# ⚠️ automatic_activity_detection 사용 시에는 불필요!
# 수동 모드에서만 침묵 감지 후 호출
await session.send_client_content(turns=None, turn_complete=True)
```

### 응답 수신

```python
async for response in session.receive():
    if response.server_content:
        # 출력 전사 (한국어 번역 텍스트)
        if response.server_content.output_transcription:
            transcript = response.server_content.output_transcription.text
            print(f"번역 자막: {transcript}")

        # 입력 전사 (영어 원문)
        if response.server_content.input_transcription:
            input_text = response.server_content.input_transcription.text
            print(f"원문: {input_text}")

        # 오디오 데이터
        if response.server_content.model_turn:
            for part in response.server_content.model_turn.parts:
                # thought=True인 경우 내부 추론이므로 무시
                if hasattr(part, 'thought') and part.thought:
                    continue
                if part.inline_data:
                    audio_data = part.inline_data.data
                    # audio/pcm;rate=24000
```

---

## 📊 오디오 포맷 명세

### 입력 오디오 (마이크 → API)

| 항목 | 값 |
|------|-----|
| Format | PCM (raw), little-endian |
| Sample Rate | 16000 Hz |
| Bit Depth | 16-bit signed integer (int16) |
| Channels | Mono (1) |
| MIME Type | **`audio/pcm;rate=16000`** ⭐ |
| Chunk Size | 1024 samples (권장) |

### 출력 오디오 (API → 스피커)

| 항목 | 값 |
|------|-----|
| Format | PCM (raw), little-endian |
| Sample Rate | **24000 Hz** |
| Bit Depth | 16-bit signed integer (int16) |
| Channels | Mono (1) |
| MIME Type | `audio/pcm;rate=24000` |

### 포맷 변환 코드

```python
import numpy as np

# float32 (-1.0 ~ 1.0) → int16 (-32768 ~ 32767)
def float32_to_int16(audio_float32: np.ndarray) -> bytes:
    audio_int16 = (audio_float32 * 32767).astype(np.int16)
    return audio_int16.tobytes()

# bytes → numpy
def bytes_to_int16(audio_bytes: bytes) -> np.ndarray:
    return np.frombuffer(audio_bytes, dtype=np.int16)
```

---

## 🎯 음성 활동 감지 (VAD)

### 자동 VAD (권장 - 동시통역용)

```python
realtime_input_config=types.RealtimeInputConfig(
    automatic_activity_detection=types.AutomaticActivityDetection(
        disabled=False,  # 자동 VAD 활성화
    )
)
```

- `send_realtime_input()` 사용 시 API가 자동으로 음성을 감지하고 응답
- `turn_complete` 수동 호출 불필요
- 동시통역처럼 실시간 응답에 최적

### 수동 VAD (턴 기반 대화용)

```python
# automatic_activity_detection 설정하지 않거나 disabled=True
# 클라이언트에서 침묵 감지 후 직접 호출
await session.send_client_content(turns=None, turn_complete=True)
```

---

## 🧠 Thinking (내부 추론)

Native Audio 모델은 기본적으로 thinking이 활성화되어 있습니다.

### Thinking 비활성화 (빠른 응답)

```python
thinking_config=types.ThinkingConfig(
    thinking_budget=0  # 0으로 설정하면 비활성화
)
```

### Thinking 활성화 시 응답 처리

```python
for part in response.server_content.model_turn.parts:
    # thought=True면 내부 추론 - UI에 표시하지 않음
    if hasattr(part, 'thought') and part.thought:
        print(f"[THOUGHT] {part.text}")  # 디버깅용
        continue
    # 실제 번역 텍스트
    if part.text:
        print(f"[TEXT] {part.text}")
```

---

## ⚠️ 주의사항 및 제한

### 1. 세션 시간 제한
- **최대 세션 시간**: 15분
- **권장**: 14분에 자동 재연결

```python
SESSION_TIMEOUT = 14 * 60  # 14분 (초)
```

### 2. Native Audio 모델 필수 설정

```python
# ❌ 오류 발생
response_modalities=["TEXT"]  # Cannot extract voices from a non-audio request

# ✅ 정상
response_modalities=["AUDIO"]
```

### 3. ⭐ send_realtime_input vs send_client_content

| 메서드 | 용도 | 특징 |
|--------|------|------|
| `send_realtime_input()` | 실시간 오디오 스트리밍 | VAD 자동 응답, 응답성 최적화 |
| `send_client_content()` | 텍스트 또는 턴 완료 신호 | 순서 보장, 컨텍스트 추가 |

### 4. 오디오 큐 관리

```python
# 권장: 작은 큐 사이즈 + 빠른 드레인
audio_queue = asyncio.Queue(maxsize=5)

# 또는 무제한 큐 + 배치 전송
audio_queue = asyncio.Queue()
while not audio_queue.empty() and len(batch) < 10:
    batch.append(audio_queue.get_nowait())
```

---

## 🎤 사용 가능한 음성

| Voice Name | 특성 |
|------------|------|
| Aoede | Bright |
| Charon | Informative |
| Fenrir | Excitable |
| **Kore** | Firm (추천) |
| Puck | Upbeat |
| Leda | Youthful |
| Orus | Firm |
| Zephyr | Bright |

```python
voice_config=types.VoiceConfig(
    prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Kore")
)
```

---

## 🆕 오디오 전사 (Audio Transcription)

SDK 버전 **1.43.0 이상** 필요!

### 설정

```python
config = types.LiveConnectConfig(
    # 모델 출력 오디오 → 텍스트 전사
    output_audio_transcription=types.AudioTranscriptionConfig(),
    # 사용자 입력 오디오 → 텍스트 전사 (선택)
    input_audio_transcription=types.AudioTranscriptionConfig(),
    ...
)
```

### 응답에서 전사 텍스트 접근

```python
# 출력 전사 (모델이 말한 내용)
response.server_content.output_transcription.text

# 입력 전사 (사용자가 말한 내용)
response.server_content.input_transcription.text
```

---

## 🧪 완전한 예시 코드

```python
import asyncio
from google import genai
from google.genai import types

async def test_live_api():
    client = genai.Client(
        api_key="YOUR_API_KEY",
        http_options={"api_version": "v1alpha"}
    )

    config = types.LiveConnectConfig(
        response_modalities=["AUDIO"],
        speech_config=types.SpeechConfig(
            voice_config=types.VoiceConfig(
                prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Kore")
            )
        ),
        thinking_config=types.ThinkingConfig(thinking_budget=0),
        output_audio_transcription=types.AudioTranscriptionConfig(),
        input_audio_transcription=types.AudioTranscriptionConfig(),
        realtime_input_config=types.RealtimeInputConfig(
            automatic_activity_detection=types.AutomaticActivityDetection(
                disabled=False,
            )
        ),
    )

    async with client.aio.live.connect(
        model="gemini-2.5-flash-native-audio-preview-12-2025",
        config=config
    ) as session:
        # 오디오 파일 읽기 (16kHz, 16-bit PCM)
        with open("test.pcm", "rb") as f:
            audio_data = f.read()

        # ⭐ 올바른 오디오 전송 방법
        await session.send_realtime_input(
            audio=types.Blob(data=audio_data, mime_type="audio/pcm;rate=16000")
        )

        # 응답 수신
        async for response in session.receive():
            if response.server_content:
                if response.server_content.output_transcription:
                    print(f"번역: {response.server_content.output_transcription.text}")

                if response.server_content.model_turn:
                    for part in response.server_content.model_turn.parts:
                        if hasattr(part, 'thought') and part.thought:
                            continue
                        if part.inline_data:
                            print(f"Audio: {len(part.inline_data.data)} bytes")

if __name__ == "__main__":
    asyncio.run(test_live_api())
```

---

## 📅 최종 업데이트
- **날짜**: 2026-01-25
- **버전**: google-genai >= 1.43.0
- **모델**: gemini-2.5-flash-native-audio-preview-12-2025

## 🔄 변경 이력
- 2026-01-25: `audio=` 파라미터 수정 (`media=` → `audio=`)
- 2026-01-25: `mime_type` 샘플레이트 추가 (`audio/pcm` → `audio/pcm;rate=16000`)
- 2026-01-25: `thinking_config` 추가 (thinking 비활성화 옵션)
- 2026-01-25: VAD 설정 섹션 추가
- 2026-01-25: 공식 문서 링크 업데이트
