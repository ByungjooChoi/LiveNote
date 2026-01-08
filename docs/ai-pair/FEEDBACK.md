# 🔴 FEEDBACK - gemini_client.py 디버깅 로그 긴급 추가

> **작성일**: 2026-01-08  
> **상태**: 🔴 긴급 - API 통신 확인 필요  
> **대상**: Cline (Gemini)

---

## 📊 현재 상황

### ✅ 해결된 문제
- Qt 스레드 안전성 문제 해결됨 (`QWidget::repaint` 경고 사라짐)
- 오디오 캡처 정상 작동 (1600 calls, 137 queued)

### ❌ 여전히 문제
- **번역 결과가 안 나옴!**
- 오디오가 큐에 들어가지만, API 응답이 없는 것으로 보임

### 🔍 문제 위치
`gemini_client.py`에 로그가 없어서 다음을 확인할 수 없음:
1. 오디오가 실제로 API로 전송되는지?
2. API에서 응답이 오는지?
3. 응답에 텍스트/오디오 데이터가 있는지?

---

## 🚨 긴급 작업: gemini_client.py 디버깅 로그 추가

### 수정 1: `_send_audio_loop()` - 오디오 전송 로그

**파일**: `src/translator/gemini_client.py`  
**함수**: `_send_audio_loop()`

**수정할 코드**:
```python
async def _send_audio_loop(self, session, audio_queue):
    """
    Continuously takes audio from queue and sends to session.
    """
    send_count = 0  # ADD: counter
    try:
        while True:
            item = await audio_queue.get()
            
            # Check for session timeout signal from monitor
            if item is SessionExpiredError or self._reconnecting:
                raise SessionExpiredError("Session timeout")

            # Handle tuple (data, rms) from capture.py
            if isinstance(item, tuple):
                audio_data = item[0]
            else:
                audio_data = item

            # Convert numpy array to bytes
            if hasattr(audio_data, 'tobytes'):
                audio_data = audio_data.tobytes()
            
            # ADD: Log send count
            send_count += 1
            if send_count % 10 == 0:
                print(f"📤 Sent {send_count} audio chunks to API ({len(audio_data)} bytes each)")
            
            # Send to Live API
            await session.send(
                input=types.LiveClientRealtimeInput(
                    media_chunks=[
                        types.Blob(data=audio_data, mime_type="audio/pcm")
                    ]
                )
            )
    except asyncio.CancelledError:
        print(f"📤 Send loop cancelled. Total sent: {send_count}")  # ADD
        pass
    except SessionExpiredError:
        raise
    except Exception as e:
        if not self._reconnecting:
            print(f"Error sending audio loop: {e}")
```

---

### 수정 2: `_stream_audio_session()` - 응답 수신 로그

**파일**: `src/translator/gemini_client.py`  
**함수**: `_stream_audio_session()`

**수정할 코드** (receive 루프 부분):
```python
try:
    response_count = 0  # ADD: counter
    while True:
        async for response in session.receive():
            response_count += 1  # ADD
            
            # ADD: Log every response
            print(f"📥 Response #{response_count} received")
            
            if response.server_content:
                if response.server_content.model_turn:
                    parts = response.server_content.model_turn.parts
                    print(f"   Parts count: {len(parts)}")  # ADD
                    
                    for i, part in enumerate(parts):
                        if part.text:
                            print(f"   [TEXT] Part {i}: {part.text[:100]}...")  # ADD
                            yield ("text", part.text)
                        elif part.inline_data and part.inline_data.mime_type.startswith("audio/"):
                            print(f"   [AUDIO] Part {i}: {len(part.inline_data.data)} bytes")  # ADD
                            yield ("audio", part.inline_data.data)
                else:
                    print(f"   ⚠️ No model_turn in response")  # ADD
            else:
                print(f"   ⚠️ No server_content in response")  # ADD
                
except asyncio.CancelledError:
    print(f"Receive loop cancelled. Total responses: {response_count}")  # ADD
```

---

## 🐛 추가 버그: 앱 종료 시 오류

### Bug 3: 앱 종료 시 qasync Signaller 오류

**증상**: 앱 종료할 때 다음 오류 발생:
```
AttributeError: 'Signaller' does not have a signal with the signature signal(PyQt_PyObject,PyQt_PyObject)
```

**원인**:
- 앱 종료 시 qasync 이벤트 루프가 먼저 닫힘
- sounddevice 콜백은 비동기라서 `stop()` 후에도 몇 번 더 호출됨
- 닫힌 루프에서 `call_soon_threadsafe()` 호출 시 오류 발생

**파일**: `src/audio/capture.py`
**함수**: `_callback()`

**수정할 코드**:
```python
def _callback(self, indata, frames, time, status):
    # ADD: Check if still running before any operations
    if not self.is_running:
        return
    
    if status:
        print(f"Audio status: {status}")
    
    # ... rest of the code
```

**또는 try-except로 감싸기**:
```python
def _callback(self, indata, frames, time, status):
    if not self.is_running:
        return
        
    if status:
        print(f"Audio status: {status}")
    
    audio_data = indata.copy()
    rms = np.sqrt(np.mean(audio_data**2))
    
    # Safely call level update
    if self.on_level_update:
        db = 20 * np.log10(rms + 1e-10)
        level = max(0, min(100, int((db + 60) * 100 / 60)))
        try:
            self.loop.call_soon_threadsafe(self.on_level_update, level)
        except (RuntimeError, AttributeError):
            # Loop is closed or signaller is gone - ignore during shutdown
            pass
    
    # ... rest with similar try-except
```

---

## 📌 수정 체크리스트 (우선순위 순)

### 긴급 - API 통신 확인
- [ ] `gemini_client.py`: `_send_audio_loop()`에 전송 카운터 로그 추가
- [ ] `gemini_client.py`: `_stream_audio_session()`에 응답 수신 로그 추가

### Bug 3 - 앱 종료 시 오류
- [ ] `capture.py`: `_callback()`에 `is_running` 체크 또는 try-except 추가

### 테스트
- [ ] 앱 실행하여 `📤 Sent` / `📥 Response` 로그 확인
- [ ] 앱 종료 시 오류 메시지 사라지는지 확인

---

## 🔍 테스트 시 확인할 로그

앱 실행 후 콘솔에서 다음 로그를 확인:

```
✅ Connected to Gemini Live API
🎤 Audio callback: 100 calls, 10 queued, last RMS: 0.0112
📤 Sent 10 audio chunks to API (2048 bytes each)  ← 이게 나와야 함!
📤 Sent 20 audio chunks to API (2048 bytes each)
📥 Response #1 received  ← 이게 나와야 번역됨!
   Parts count: 2
   [TEXT] Part 0: 안녕하세요...
   [AUDIO] Part 1: 4096 bytes
```

---

## ⚠️ 예상 시나리오

### 시나리오 A: `📤 Sent` 로그가 안 나옴
→ `_send_audio_loop()`가 큐에서 데이터를 못 가져오고 있음
→ 큐 데이터 형식 문제일 수 있음

### 시나리오 B: `📤 Sent` 나오지만 `📥 Response` 안 나옴
→ API가 응답을 안 보내고 있음
→ 오디오 포맷(sample rate, bit depth) 문제일 수 있음
→ 모델 설정 문제일 수 있음

### 시나리오 C: `📥 Response` 나오지만 `No model_turn` 또는 `No server_content`
→ API 응답 형식이 예상과 다름
→ 응답 객체 전체를 print해서 확인 필요

---

## 📝 완료 보고

```bash
git add -A
git commit -m "debug: add comprehensive logging to gemini_client.py"
```
