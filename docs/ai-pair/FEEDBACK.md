# 🔴 FEEDBACK - turn_complete 신호 추가 필요!

> **작성일**: 2026-01-08  
> **상태**: 🔴 긴급 - API 응답을 받으려면 turn_complete 필요!  
> **대상**: Cline (Gemini)

---

## 📊 테스트 결과

### ✅ API는 정상 작동함!

`python tests/test_live_api.py` 실행 결과:
```
Testing: AUDIO only
Connected successfully!
--- Response #1 ---
  [TEXT]: **Analyzing Korean Translation**...
--- Response #2 ---
  [AUDIO]: audio/pcm;rate=24000, 46080 bytes
```

### ❌ 앱에서 응답이 안 오는 이유

**테스트 코드**: 텍스트 메시지 + `turn_complete=True` → 응답 받음  
**앱 코드**: 오디오만 전송, turn_complete 없음 → 응답 없음

---

## 🔧 수정 1: turn_complete 신호 추가

Live API는 **turn이 완료되었다는 신호**를 받아야 응답합니다.

### 방법 A: 주기적으로 turn_complete 전송 (추천)

**파일**: `src/translator/gemini_client.py`  
**함수**: `_send_audio_loop()` 수정

침묵 감지 후 또는 일정 시간마다 turn_complete 전송:

```python
async def _send_audio_loop(self, session, audio_queue):
    """
    Continuously takes audio from queue and sends to session.
    """
    send_count = 0
    last_audio_time = time.time()
    SILENCE_TIMEOUT = 1.5  # 1.5초 침묵 후 turn 완료
    
    try:
        while True:
            try:
                # Non-blocking get with timeout
                item = await asyncio.wait_for(audio_queue.get(), timeout=0.5)
                
                # Check for session timeout signal
                if item is SessionExpiredError or self._reconnecting:
                    raise SessionExpiredError("Session timeout")

                # Handle tuple (data, rms) from capture.py
                if isinstance(item, tuple):
                    audio_data = item[0]
                    rms = item[1] if len(item) > 1 else 0
                else:
                    audio_data = item
                    rms = 0

                # Convert float32 to int16
                if hasattr(audio_data, 'tobytes'):
                    if hasattr(audio_data, 'dtype') and audio_data.dtype == np.float32:
                        audio_data = (audio_data * 32767).astype(np.int16)
                    audio_data = audio_data.tobytes()
                
                # Log send count
                send_count += 1
                if send_count % 10 == 0:
                    print(f"Sent {send_count} audio chunks to API ({len(audio_data)} bytes each)")

                # Send audio
                await session.send_realtime_input(
                    media=types.Blob(data=audio_data, mime_type="audio/pcm")
                )
                
                last_audio_time = time.time()
                
            except asyncio.TimeoutError:
                # Check for silence timeout
                silence_duration = time.time() - last_audio_time
                if silence_duration >= SILENCE_TIMEOUT:
                    # Send turn_complete to trigger response
                    print(f"Silence detected ({silence_duration:.1f}s), sending turn_complete")
                    await session.send_client_content(
                        turns=None,
                        turn_complete=True
                    )
                    last_audio_time = time.time()  # Reset timer
                    
    except asyncio.CancelledError:
        print(f"Send loop cancelled. Total sent: {send_count}")
    except SessionExpiredError:
        raise
    except Exception as e:
        if not self._reconnecting:
            print(f"Error sending audio loop: {e}")
```

---

## 🔧 수정 2: Deprecated API 수정

### 현재 코드 (deprecated):
```python
await session.send(
    input=types.LiveClientRealtimeInput(
        media_chunks=[types.Blob(data=audio_data, mime_type="audio/pcm")]
    )
)
```

### 수정할 코드:
```python
await session.send_realtime_input(
    media=types.Blob(data=audio_data, mime_type="audio/pcm")
)
```

---

## 🔧 수정 3: 오디오 재생 sample rate 수정

API 응답 오디오: `audio/pcm;rate=24000` (24000Hz)

**파일**: `src/audio/playback.py`

재생 시 sample rate를 24000Hz로 변경하거나, 응답에서 sample rate를 파싱:

```python
# 응답 mime_type에서 rate 파싱
# "audio/pcm;rate=24000" → sample_rate = 24000
```

---

## 📌 수정 체크리스트

### 필수
- [ ] `gemini_client.py`: 침묵 감지 후 `turn_complete` 전송
- [ ] `gemini_client.py`: `session.send()` → `session.send_realtime_input()` 변경

### 선택 (나중에)
- [ ] `playback.py`: 오디오 재생 sample rate를 24000Hz로 변경

---

## 🔍 수정 후 예상 로그

```
Connected to Gemini Live API
Sent 10 audio chunks to API (2048 bytes each)
Sent 20 audio chunks to API (2048 bytes each)
Silence detected (1.5s), sending turn_complete  ← 새로 추가!
Response #1 received  ← 이제 응답이 와야 함!
   [RAW] LiveServerMessage(...)
   [TEXT] Part 0: 안녕하세요...
   [AUDIO] Part 1: 46080 bytes
```

---

## 📝 완료 보고

```bash
git add -A
git commit -m "fix: add turn_complete signal and update to new API methods"
```
