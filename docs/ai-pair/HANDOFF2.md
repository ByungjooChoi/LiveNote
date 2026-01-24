# 🚀 LiveNote - Google AI Studio HANDOFF

> **목적**: Google AI Studio에서 테스트/개발용  
> **Git**: 커밋하지 않음 (임시 파일)

---

## 📋 프로젝트 개요

**LiveNote** - 실시간 영어→한국어 음성 번역 데스크톱 앱

| 항목 | 내용 |
|------|------|
| Language | Python 3.11+ |
| GUI | PyQt6 + qasync |
| AI API | Gemini Live API (WebSocket) |
| Package | `google-genai` |
| Model | `gemini-2.5-flash-native-audio-preview-12-2025` |
| Audio | sounddevice, 16kHz mono int16 PCM |

---

## 🔧 핵심 API 사용법

### 1. 연결 설정

```python
from google import genai
from google.genai import types

client = genai.Client(api_key="YOUR_API_KEY", http_options={"api_version": "v1alpha"})

config = types.LiveConnectConfig(
    response_modalities=["AUDIO"],  # Native Audio 모델 필수!
    speech_config=types.SpeechConfig(
        voice_config=types.VoiceConfig(
            prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Kore")
        )
    ),
    system_instruction=types.Content(
        parts=[types.Part(text="""You are a real-time English to Korean interpreter.

RULES:
1. Translate English speech to natural Korean immediately
2. Do NOT explain - just translate
3. Keep translations concise
""")]
    )
)
```

### 2. 세션 시작

```python
async with client.aio.live.connect(
    model="gemini-2.5-flash-native-audio-preview-12-2025",
    config=config
) as session:
    # 오디오 전송 및 응답 수신
```

### 3. 오디오 전송

```python
# 오디오 데이터: 16kHz, mono, int16 PCM bytes
await session.send_realtime_input(
    media=types.Blob(data=audio_bytes, mime_type="audio/pcm")
)
```

### 4. 응답 트리거 (중요!)

```python
# 침묵 감지 후 반드시 호출! (빈 텍스트 포함 필수)
await session.send(
    input=types.LiveClientContent(
        turns=[types.Content(parts=[types.Part(text="")])],
        turn_complete=True
    )
)
```

### 5. 응답 수신

```python
async for response in session.receive():
    if response.server_content and response.server_content.model_turn:
        for part in response.server_content.model_turn.parts:
            # thought=True는 내부 사고 (번역 아님) - 스킵!
            if hasattr(part, 'thought') and part.thought:
                continue
            if part.text:
                print(f"번역: {part.text}")
            if part.inline_data:
                # audio/pcm;rate=24000
                audio_data = part.inline_data.data
```

---

## 📊 오디오 포맷

### 입력 (마이크 → API)
- Format: PCM (raw)
- Sample Rate: **16000 Hz**
- Bit Depth: **16-bit signed integer (int16)**
- Channels: Mono (1)
- MIME Type: `audio/pcm`

### 출력 (API → 스피커)
- Format: PCM (raw)
- Sample Rate: **24000 Hz**
- Bit Depth: 16-bit signed integer (int16)
- Channels: Mono (1)
- MIME Type: `audio/pcm;rate=24000`

### 포맷 변환

```python
import numpy as np

# float32 → int16
def float32_to_int16(audio_float32: np.ndarray) -> bytes:
    audio_int16 = (audio_float32 * 32767).astype(np.int16)
    return audio_int16.tobytes()
```

---

## ⚠️ 주의사항

1. **세션 시간**: 최대 15분 (14분에 재연결 권장)

2. **response_modalities**: Native Audio 모델은 `["AUDIO"]` 필수
   - `["TEXT"]` 사용하면 오류: `Cannot extract voices from a non-audio request`

3. **turn_complete**: `turns` 파라미터에 빈 텍스트라도 포함해야 함
   - `turns=None` 또는 `turns=[]` 사용하면 오류

4. **thought 응답**: `part.thought=True`는 번역이 아닌 내부 사고
   - UI에 표시하면 안 됨

---

## 🧪 테스트 코드

```python
import asyncio
import numpy as np
from google import genai
from google.genai import types

API_KEY = "YOUR_API_KEY"
MODEL = "gemini-2.5-flash-native-audio-preview-12-2025"

def generate_test_audio(duration=2.0, sample_rate=16000):
    """2초 사인파 생성"""
    t = np.linspace(0, duration, int(sample_rate * duration), dtype=np.float32)
    audio = np.sin(2 * np.pi * 440 * t) * 0.3
    return (audio * 32767).astype(np.int16).tobytes()

async def test():
    client = genai.Client(api_key=API_KEY, http_options={"api_version": "v1alpha"})
    
    config = types.LiveConnectConfig(
        response_modalities=["AUDIO"],
        speech_config=types.SpeechConfig(
            voice_config=types.VoiceConfig(
                prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Kore")
            )
        ),
        system_instruction=types.Content(
            parts=[types.Part(text="You are a Korean translator.")]
        )
    )
    
    audio = generate_test_audio()
    chunks = [audio[i:i+2048] for i in range(0, len(audio), 2048)]
    
    async with client.aio.live.connect(model=MODEL, config=config) as session:
        print("Connected!")
        
        # Send audio
        for chunk in chunks:
            await session.send_realtime_input(
                media=types.Blob(data=chunk, mime_type="audio/pcm")
            )
        print(f"Sent {len(chunks)} chunks")
        
        # Trigger response
        await session.send(
            input=types.LiveClientContent(
                turns=[types.Content(parts=[types.Part(text="")])],
                turn_complete=True
            )
        )
        
        # Receive
        async for response in session.receive():
            if response.server_content:
                if response.server_content.model_turn:
                    for part in response.server_content.model_turn.parts:
                        if part.text:
                            print(f"TEXT: {part.text}")
                        if part.inline_data:
                            print(f"AUDIO: {len(part.inline_data.data)} bytes")
                if response.server_content.turn_complete:
                    break

asyncio.run(test())
```

---

## 📂 현재 프로젝트 구조

```
LiveNote/
├── src/
│   ├── main.py                 # 앱 진입점
│   ├── audio/
│   │   ├── capture.py          # 마이크 캡처 (16kHz, float32 → int16)
│   │   ├── device_manager.py   # 오디오 장치 관리
│   │   └── playback.py         # 오디오 재생 (24kHz)
│   ├── translator/
│   │   └── gemini_client.py    # Live API 클라이언트 ★
│   └── ui/
│       └── main_window.py      # PyQt6 UI
├── tests/
│   ├── test_live_api.py        # API 테스트
│   └── test_audio_stream.py    # 오디오 스트리밍 테스트
└── docs/
    ├── REFERENCE.md            # API 레퍼런스
    └── ai-pair/
        ├── HANDOFF.md          # 작업 지시서
        └── FEEDBACK.md         # 코드 리뷰
```

---

## 🐛 현재 이슈

### 문제
- 오디오 입력은 캡처되지만 (레벨 미터 작동)
- 번역 대신 모델의 "thought" (내부 사고)만 출력됨
- 응답이 느림

### 원인 추정
1. `thought=True` 응답 필터링 안 됨
2. 시스템 프롬프트가 명확하지 않음
3. 오디오 입력 품질/포맷 문제 가능성

### 해결 방안
1. `thought=True` 응답 스킵
2. 시스템 프롬프트 개선
3. 다른 오디오 장치로 테스트

---

## 📚 공식 문서

- Live API: https://ai.google.dev/api/live
- Live Guide: https://ai.google.dev/gemini-api/docs/live-guide
- Session: https://ai.google.dev/gemini-api/docs/live-session?hl=ko
- Native Audio: https://ai.google.dev/gemini-api/docs/models#gemini-2.5-flash-native-audio-preview
