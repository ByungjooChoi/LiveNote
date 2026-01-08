# 📚 Gemini Live API Reference Documentation

이 문서는 LiveNote 프로젝트에서 사용하는 Google Gemini Live API의 핵심 참고 자료입니다.

---

## 📖 공식 문서 링크

### 1. Live API 공식 가이드
- **URL**: https://ai.google.dev/api/live
- **내용**: WebSocket 기반 실시간 양방향 통신 API

### 2. Live API 사용 가이드 (튜토리얼)
- **URL**: https://ai.google.dev/gemini-api/docs/live-guide
- **내용**: Live API 시작하기, 오디오/비디오 스트리밍 예제

### 3. Live API 세션 관리 (한국어)
- **URL**: https://ai.google.dev/gemini-api/docs/live-session?hl=ko
- **내용**: 세션 생성, 유지, 종료 방법 (한국어 문서)

### 4. Gemini 2.5 Native Audio 모델
- **URL**: https://ai.google.dev/gemini-api/docs/models#gemini-2.5-flash-native-audio-preview
- **모델명**: `gemini-2.5-flash-native-audio-preview-12-2025`
- **특징**: 음성 입력 → 텍스트 + 음성 출력 동시 지원

### 5. Python SDK (google-genai)
- **URL**: https://ai.google.dev/gemini-api/docs/sdks
- **패키지**: `pip install google-genai`
- **참고**: `google-generativeai`와 다름! (새 SDK)

---

## 🔧 핵심 API 사용법

### 연결 설정

```python
from google import genai
from google.genai import types

client = genai.Client(api_key="YOUR_API_KEY")

config = types.LiveConnectConfig(
    response_modalities=["AUDIO"],  # Native Audio 모델 필수!
    speech_config=types.SpeechConfig(
        voice_config=types.VoiceConfig(
            prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Kore")
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

### 오디오 전송 (새 API - 권장)

```python
# ✅ 권장: send_realtime_input()
await session.send_realtime_input(
    media=types.Blob(data=audio_bytes, mime_type="audio/pcm")
)

# ⚠️ Deprecated: session.send()
await session.send(
    input=types.LiveClientRealtimeInput(
        media_chunks=[types.Blob(data=audio_bytes, mime_type="audio/pcm")]
    )
)
```

### 응답 트리거 (중요!)

```python
# 침묵 감지 후 반드시 호출해야 응답이 옴!
await session.send_client_content(turns=None, turn_complete=True)
```

### 응답 수신

```python
async for response in session.receive():
    if response.server_content:
        for part in response.server_content.model_turn.parts:
            if part.text:
                print(f"번역: {part.text}")
            if part.inline_data:
                audio_data = part.inline_data.data
                mime_type = part.inline_data.mime_type
                # audio/pcm;rate=24000
```

---

## 📊 오디오 포맷 명세

### 입력 오디오 (마이크 → API)

| 항목 | 값 |
|------|-----|
| Format | PCM (raw) |
| Sample Rate | 16000 Hz |
| Bit Depth | 16-bit signed integer (int16) |
| Channels | Mono (1) |
| MIME Type | `audio/pcm` |

### 출력 오디오 (API → 스피커)

| 항목 | 값 |
|------|-----|
| Format | PCM (raw) |
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

### 3. turn_complete 필수!

API는 `turn_complete=True` 신호를 받아야만 응답을 생성합니다.

```python
# 침묵 1.5초 감지 후 호출
await session.send_client_content(turns=None, turn_complete=True)
```

### 4. 텍스트 + 오디오 동시 전송 금지

```python
# ❌ 오류: Request contains an invalid argument
await session.send_client_content(turns=[text_turn], turn_complete=True)
await session.send_realtime_input(media=audio_blob)

# ✅ 정상: 오디오만 전송
await session.send_realtime_input(media=audio_blob)
await session.send_client_content(turns=None, turn_complete=True)
```

---

## 🎤 사용 가능한 음성

| Voice Name | 언어 | 특성 |
|------------|------|------|
| Aoede | 다국어 | Bright |
| Charon | 다국어 | Informative |
| Fenrir | 다국어 | Excitable |
| **Kore** | 다국어 | Firm (추천) |
| Puck | 다국어 | Upbeat |

```python
voice_config=types.VoiceConfig(
    prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Kore")
)
```

---

## 🧪 테스트 코드 예시

```python
import asyncio
from google import genai
from google.genai import types

async def test_live_api():
    client = genai.Client(api_key="YOUR_API_KEY")
    
    config = types.LiveConnectConfig(
        response_modalities=["AUDIO"],
        speech_config=types.SpeechConfig(
            voice_config=types.VoiceConfig(
                prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Kore")
            )
        ),
    )
    
    async with client.aio.live.connect(
        model="gemini-2.5-flash-native-audio-preview-12-2025",
        config=config
    ) as session:
        # 오디오 파일 읽기
        with open("test.pcm", "rb") as f:
            audio_data = f.read()
        
        # 오디오 전송
        await session.send_realtime_input(
            media=types.Blob(data=audio_data, mime_type="audio/pcm")
        )
        
        # 응답 트리거
        await session.send_client_content(turns=None, turn_complete=True)
        
        # 응답 수신
        async for response in session.receive():
            if response.server_content:
                for part in response.server_content.model_turn.parts:
                    if part.text:
                        print(f"Text: {part.text}")
                    if part.inline_data:
                        print(f"Audio: {len(part.inline_data.data)} bytes")

if __name__ == "__main__":
    asyncio.run(test_live_api())
```

---

## 📅 최종 업데이트
- **날짜**: 2026-01-08
- **버전**: google-genai 1.x
- **모델**: gemini-2.5-flash-native-audio-preview-12-2025
