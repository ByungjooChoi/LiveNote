# 🔴 FEEDBACK - Native Audio 모델 지원 추가

> **작성일**: 2026-01-07  
> **상태**: 🔴 수정 필요  
> **대상**: Cline (Gemini)

---

## 📋 에러 분석

### 에러 메시지
```
Cannot extract voices from a non-audio request
```

### 원인
- `gemini-2.5-flash-native-audio-preview-12-2025`는 **Native Audio** 모델
- 이 모델은 **음성 출력을 반드시 포함**해야 함
- 현재 `response_modalities=["TEXT"]`만 설정되어 있어서 에러 발생

### Sound Source 문제가 아님
- 로그에서 `Audio capture started on device 0` 확인 → 오디오 캡처는 정상
- 문제는 Gemini API 연결 설정 (`LiveConnectConfig`)

---

## 🔴 수정해야 할 사항

### Issue 1: Native Audio 모델 지원
**파일**: `src/translator/gemini_client.py`  
**라인**: 64-69

**현재 코드**:
```python
config = types.LiveConnectConfig(
    response_modalities=["TEXT"],
    system_instruction=types.Content(
        parts=[types.Part(text="You are a real-time interpreter...")]
    )
)
```

**수정할 코드**:
```python
# Check if using Native Audio model
is_native_audio = "native-audio" in self.model_name

if is_native_audio:
    # Native Audio model - request both TEXT and AUDIO
    config = types.LiveConnectConfig(
        response_modalities=["TEXT", "AUDIO"],  # 둘 다 요청!
        speech_config=types.SpeechConfig(
            voice_config=types.VoiceConfig(
                prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Aoede")
            )
        ),
        system_instruction=types.Content(
            parts=[types.Part(text="You are a real-time interpreter. Listen to English speech and respond with Korean translation in both text and speech. Speak naturally in Korean.")]
        )
    )
else:
    # Standard model - TEXT only
    config = types.LiveConnectConfig(
        response_modalities=["TEXT"],
        system_instruction=types.Content(
            parts=[types.Part(text="You are a real-time interpreter. Translate English speech to Korean immediately as you hear it. Provide translations in a natural, conversational Korean style.")]
        )
    )
```

> **참고**: `["TEXT", "AUDIO"]`로 설정하면 텍스트와 음성 응답을 모두 받을 수 있습니다. 만약 이것도 에러가 발생하면 `["AUDIO"]`만 설정하고, 음성 응답에 포함된 transcription을 추출해야 합니다.

---

### Issue 2: 음성 응답 처리 추가
**파일**: `src/translator/gemini_client.py`  
**라인**: 82-86 (receive loop)

**현재 코드**:
```python
async for response in session.receive():
    if response.server_content and response.server_content.model_turn:
        for part in response.server_content.model_turn.parts:
            if part.text:
                yield part.text
```

**수정할 코드** (TEXT + AUDIO 둘 다 처리):
```python
async for response in session.receive():
    if response.server_content and response.server_content.model_turn:
        for part in response.server_content.model_turn.parts:
            # Handle text response
            if part.text:
                yield ("text", part.text)
            # Handle audio response (Native Audio model)
            elif part.inline_data and part.inline_data.mime_type.startswith("audio/"):
                yield ("audio", part.inline_data.data)
```

---

### Issue 3: MainWindow에서 음성 출력 처리
**파일**: `src/ui/main_window.py`  
**라인**: 157-171 (process_audio_stream)

**수정 방향**:
- `stream_audio()`가 이제 `(type, data)` 튜플을 반환
- `type == "text"`이면 텍스트 표시
- `type == "audio"`이면 스피커로 재생 (선택사항)

**수정할 코드**:
```python
async def process_audio_stream(self):
    try:
        async for item in self.gemini_client.stream_audio(self.audio_capture.queue):
            if isinstance(item, tuple):
                item_type, data = item
                
                if item_type == "text":
                    if not data or not data.strip():
                        continue
                    self.text_area.moveCursor(self.text_area.textCursor().MoveOperation.End)
                    self.text_area.insertPlainText(data + " ")
                    self.text_area.moveCursor(self.text_area.textCursor().MoveOperation.End)
                    self.file_writer.write_line(data)
                    
                elif item_type == "audio":
                    # Optional: Play audio through speakers
                    # For now, just log that we received audio
                    print(f"Received audio chunk: {len(data)} bytes")
                    # TODO: Implement audio playback using sounddevice or pyaudio
            else:
                # Backward compatibility for text-only response
                text = item
                if not text or not text.strip():
                    continue
                self.text_area.moveCursor(self.text_area.textCursor().MoveOperation.End)
                self.text_area.insertPlainText(text + " ")
                self.text_area.moveCursor(self.text_area.textCursor().MoveOperation.End)
                self.file_writer.write_line(text)
                
    except Exception as e:
        print(f"Stream processing error: {e}")
        self.status_bar.showMessage(f"Stream Error: {e}")
```

---

### Issue 4 (선택): 음성 재생 기능 추가
**파일**: `src/audio/playback.py` (새로 생성)

음성 출력을 실제로 재생하려면 새 모듈 추가:

```python
import sounddevice as sd
import numpy as np

class AudioPlayback:
    """Plays audio data through speakers."""
    
    def __init__(self, sample_rate=24000):
        self.sample_rate = sample_rate
    
    def play(self, audio_data: bytes):
        """Play PCM audio data."""
        try:
            # Convert bytes to numpy array (assuming 16-bit PCM)
            audio_array = np.frombuffer(audio_data, dtype=np.int16)
            # Normalize to float32 for sounddevice
            audio_float = audio_array.astype(np.float32) / 32768.0
            sd.play(audio_float, self.sample_rate)
        except Exception as e:
            print(f"Audio playback error: {e}")
```

---

## 📌 수정 체크리스트

- [ ] `gemini_client.py`: Native Audio 모델 감지 및 `response_modalities=["AUDIO"]` 설정
- [ ] `gemini_client.py`: `speech_config` 추가 (Native Audio일 때만)
- [ ] `gemini_client.py`: 응답에서 audio parts 처리
- [ ] `main_window.py`: `(type, data)` 튜플 처리
- [ ] (선택) `audio/playback.py`: 음성 재생 모듈 추가

---

## 🔍 테스트 방법

1. **앱 실행**: `python -m src.main`
2. **모델 선택**: Settings → `gemini-2.5-flash-native-audio-preview-12-2025` 선택 → Save
3. **번역 시작**: Start Translation
4. **확인할 것**:
   - `Cannot extract voices` 에러가 발생하지 않아야 함
   - 콘솔에 `Received audio chunk: XXX bytes` 메시지 출력 (음성 응답 수신 확인)
   - 텍스트 영역에 번역 결과 표시 (Native Audio는 text 없이 audio만 반환할 수 있음)

---

## 📝 참고 사항

**Native Audio 모델 vs 일반 모델:**

| 모델 | response_modalities | 출력 |
|------|---------------------|------|
| `gemini-2.0-flash-exp` | `["TEXT"]` | 텍스트만 |
| `gemini-2.5-flash-native-audio-preview` | `["AUDIO"]` | 음성 (+ 텍스트 transcription 포함 가능) |

**중요**: Native Audio 모델은 TEXT와 AUDIO를 동시에 출력하지 않을 수 있음. 음성으로 응답하고, 해당 음성의 transcription을 별도로 제공할 수 있음.
