# 🔴 FEEDBACK - Native Audio 테스트 코드 먼저 작성

> **작성일**: 2026-01-07  
> **상태**: 🔴 수정 필요  
> **대상**: Cline (Gemini)

---

## 📚 참조 문서 (반드시 읽을 것!)

다음 Google 공식 문서를 먼저 읽고 이해한 후 작업하세요:

1. **마이크 스트림 예제**: https://ai.google.dev/gemini-api/docs/live?hl=ko&example=mic-stream
2. **Live API 가이드**: https://ai.google.dev/gemini-api/docs/live-guide?hl=ko
3. **세션 관리**: https://ai.google.dev/gemini-api/docs/live-session?hl=ko

> **중요**: 문서에 따르면 TEXT와 AUDIO를 **동시에 응답**받을 수 있을 수 있음. 테스트로 확인 필요.

---

## 🎯 작업 순서

### Phase 1: 테스트 코드 작성 (먼저!)

앱 코드를 수정하기 전에, **독립적인 테스트 스크립트**를 먼저 작성해서 응답 구조를 확인하세요.

**파일 생성**: `tests/test_live_api.py`

```python
"""
Gemini Live API 테스트 스크립트
목적: Native Audio 모델의 응답 구조 확인
"""
import asyncio
import os
import numpy as np
import sounddevice as sd
from google import genai
from google.genai import types

# Load API key from environment
API_KEY = os.environ.get("GEMINI_API_KEY")
MODEL_NAME = "gemini-2.5-flash-native-audio-preview-12-2025"

async def test_live_api():
    """Test Live API connection and response structure."""
    
    client = genai.Client(api_key=API_KEY, http_options={"api_version": "v1alpha"})
    
    # Test different configurations
    configs_to_test = [
        {
            "name": "AUDIO only",
            "config": types.LiveConnectConfig(
                response_modalities=["AUDIO"],
                speech_config=types.SpeechConfig(
                    voice_config=types.VoiceConfig(
                        prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Aoede")
                    )
                ),
                system_instruction=types.Content(
                    parts=[types.Part(text="Say 'Hello, this is a test' in Korean.")]
                )
            )
        },
        {
            "name": "TEXT only",
            "config": types.LiveConnectConfig(
                response_modalities=["TEXT"],
                system_instruction=types.Content(
                    parts=[types.Part(text="Say 'Hello, this is a test' in Korean.")]
                )
            )
        },
        {
            "name": "TEXT and AUDIO",
            "config": types.LiveConnectConfig(
                response_modalities=["TEXT", "AUDIO"],
                speech_config=types.SpeechConfig(
                    voice_config=types.VoiceConfig(
                        prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Aoede")
                    )
                ),
                system_instruction=types.Content(
                    parts=[types.Part(text="Say 'Hello, this is a test' in Korean.")]
                )
            )
        }
    ]
    
    for test_config in configs_to_test:
        print(f"\n{'='*60}")
        print(f"Testing: {test_config['name']}")
        print(f"{'='*60}")
        
        try:
            async with client.aio.live.connect(model=MODEL_NAME, config=test_config['config']) as session:
                print("✅ Connected successfully!")
                
                # Send a simple text message to trigger response
                await session.send(
                    input=types.LiveClientContent(
                        turns=[types.Content(
                            parts=[types.Part(text="Please respond now.")]
                        )],
                        turn_complete=True
                    )
                )
                
                # Receive and analyze responses
                response_count = 0
                async for response in session.receive():
                    response_count += 1
                    print(f"\n--- Response #{response_count} ---")
                    print(f"Type: {type(response)}")
                    
                    if response.server_content:
                        sc = response.server_content
                        print(f"server_content attributes: {[a for a in dir(sc) if not a.startswith('_')]}")
                        
                        # Check for model_turn
                        if sc.model_turn:
                            print(f"  model_turn.parts count: {len(sc.model_turn.parts)}")
                            for i, part in enumerate(sc.model_turn.parts):
                                print(f"    Part {i}: {type(part)}")
                                if part.text:
                                    print(f"      TEXT: {part.text[:100]}...")
                                if part.inline_data:
                                    print(f"      AUDIO: {part.inline_data.mime_type}, {len(part.inline_data.data)} bytes")
                        
                        # Check for transcription
                        if hasattr(sc, 'output_transcription') and sc.output_transcription:
                            print(f"  output_transcription: {sc.output_transcription}")
                        if hasattr(sc, 'input_transcription') and sc.input_transcription:
                            print(f"  input_transcription: {sc.input_transcription}")
                        
                        # Check turn_complete
                        if hasattr(sc, 'turn_complete') and sc.turn_complete:
                            print("  turn_complete: True")
                            break
                    
                    if response_count > 20:  # Safety limit
                        print("Reached response limit")
                        break
                        
        except Exception as e:
            print(f"❌ Error: {e}")
            import traceback
            traceback.print_exc()
        
        await asyncio.sleep(1)  # Wait between tests

async def test_with_audio_input():
    """Test with actual microphone input."""
    print("\n" + "="*60)
    print("Testing with microphone input")
    print("="*60)
    
    client = genai.Client(api_key=API_KEY, http_options={"api_version": "v1alpha"})
    
    config = types.LiveConnectConfig(
        response_modalities=["AUDIO"],  # or ["TEXT", "AUDIO"] if supported
        speech_config=types.SpeechConfig(
            voice_config=types.VoiceConfig(
                prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Aoede")
            )
        ),
        system_instruction=types.Content(
            parts=[types.Part(text="You are a real-time interpreter. Translate English speech to Korean.")]
        )
    )
    
    try:
        async with client.aio.live.connect(model=MODEL_NAME, config=config) as session:
            print("✅ Connected! Speak into your microphone...")
            print("Press Ctrl+C to stop")
            
            # Audio capture settings
            SAMPLE_RATE = 16000
            CHUNK_SIZE = 1024
            
            audio_queue = asyncio.Queue()
            
            def audio_callback(indata, frames, time, status):
                if status:
                    print(f"Audio status: {status}")
                # Convert float32 to int16
                audio_int16 = (indata * 32767).astype(np.int16)
                asyncio.get_event_loop().call_soon_threadsafe(
                    audio_queue.put_nowait, audio_int16.tobytes()
                )
            
            # Start audio capture
            stream = sd.InputStream(
                samplerate=SAMPLE_RATE,
                channels=1,
                dtype='float32',
                blocksize=CHUNK_SIZE,
                callback=audio_callback
            )
            stream.start()
            
            # Tasks
            async def send_audio():
                while True:
                    audio_data = await audio_queue.get()
                    await session.send(
                        input=types.LiveClientRealtimeInput(
                            media_chunks=[types.Blob(data=audio_data, mime_type="audio/pcm")]
                        )
                    )
            
            async def receive_responses():
                async for response in session.receive():
                    if response.server_content:
                        sc = response.server_content
                        if sc.model_turn:
                            for part in sc.model_turn.parts:
                                if part.text:
                                    print(f"[TEXT] {part.text}")
                                if part.inline_data:
                                    print(f"[AUDIO] {len(part.inline_data.data)} bytes")
                        if hasattr(sc, 'output_transcription') and sc.output_transcription:
                            print(f"[TRANSCRIPTION] {sc.output_transcription}")
            
            send_task = asyncio.create_task(send_audio())
            receive_task = asyncio.create_task(receive_responses())
            
            try:
                await asyncio.gather(send_task, receive_task)
            except asyncio.CancelledError:
                pass
            finally:
                stream.stop()
                
    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    print("Gemini Live API Test Script")
    print(f"API Key: {'✅ Set' if API_KEY else '❌ Missing'}")
    print(f"Model: {MODEL_NAME}")
    
    if not API_KEY:
        print("Set GEMINI_API_KEY environment variable first!")
        exit(1)
    
    # Run tests
    asyncio.run(test_live_api())
    
    # Uncomment to test with microphone
    # asyncio.run(test_with_audio_input())
```

---

### Phase 2: 테스트 결과 분석

테스트 스크립트 실행 후 다음을 확인:

1. **어떤 config가 작동하는지**:
   - `["AUDIO"]` only
   - `["TEXT"]` only  
   - `["TEXT", "AUDIO"]` 둘 다

2. **응답 구조**:
   - `response.server_content.model_turn.parts`에 뭐가 있는지
   - `output_transcription`이 있는지
   - 텍스트와 오디오가 어떻게 분리되는지

3. **SESSION_LOG.md에 결과 기록**:
```markdown
## Live API Test Results
- Config tested: ...
- Working config: ...
- Response structure:
  - text: ...
  - audio: ...
  - transcription: ...
```

---

### Phase 3: 세션 관리 추가

문서에 따르면 **세션이 15분으로 제한**됨. 세션 관리 로직 필요:

**`src/translator/gemini_client.py`에 추가**:

```python
class GeminiClient:
    SESSION_TIMEOUT = 14 * 60  # 14분 (여유 1분)
    
    def __init__(self):
        # ... existing code ...
        self.session_start_time = None
    
    async def _check_session_timeout(self):
        """Check if session needs to be refreshed."""
        if self.session_start_time:
            elapsed = time.time() - self.session_start_time
            if elapsed > self.SESSION_TIMEOUT:
                print("Session timeout approaching, reconnecting...")
                await self._reconnect()
    
    async def _reconnect(self):
        """Reconnect to Live API."""
        # Implement reconnection logic
        pass
```

---

### Phase 4: 앱 코드 수정

테스트 결과를 바탕으로 앱 코드 수정.

---

## 📌 수정 체크리스트

- [ ] `tests/test_live_api.py` 생성 및 실행
- [ ] 테스트 결과를 `SESSION_LOG.md`에 기록
- [ ] 작동하는 config 확인 후 `gemini_client.py` 수정
- [ ] (필요시) 세션 관리 로직 추가
- [ ] (선택) 오디오 출력 + 볼륨 조절 UI 추가

---

## 🔍 테스트 실행 방법

```bash
# 환경 변수 설정 (PowerShell)
$env:GEMINI_API_KEY = "your-api-key"

# 테스트 실행
python tests/test_live_api.py
```

---

## 📝 완료 보고

테스트 결과와 함께 다음을 `SESSION_LOG.md`에 기록:

```markdown
## Live API Investigation Results
- Date: YYYY-MM-DD
- Test configs tried: ...
- Working config: ...
- Response structure observed: ...
- Session timeout handling: needed/not needed
- Next steps: ...
```
