# 🔴 FEEDBACK - 버그 수정 필요!

> **작성일**: 2026-01-08  
> **상태**: 🔴 긴급 - 두 가지 버그 수정 필요  
> **대상**: Cline (Gemini)

---

## 📊 오류 로그

```
Silence detected (1.5s), sending turn_complete
Send loop cancelled. Total sent: 0  ← 오디오를 하나도 안 보냄!
Live API Connection Error: Request contains an invalid argument
```

---

## 🐛 버그 1: `turns=[]` → `turns=None`

**파일**: `src/translator/gemini_client.py`  
**라인**: 192

### 현재 코드 (버그):
```python
await session.send_client_content(turns=[], turn_complete=True)
```

### 수정할 코드:
```python
await session.send_client_content(turns=None, turn_complete=True)
```

**원인**: 빈 배열 `[]`을 보내면 API가 `invalid argument` 오류 반환

---

## 🐛 버그 2: 오디오 전송 전에 turn_complete 보내면 안됨

**문제**: 앱 시작 직후 1.5초 동안 오디오가 없어서 `turn_complete`를 보냈는데, **그 전에 오디오를 한 번도 보내지 않았음** (`Total sent: 0`)

오디오 없이 `turn_complete`만 보내면 API 오류 발생!

### 수정할 코드:

```python
async def _send_audio_loop(self, session, audio_queue):
    send_count = 0
    last_audio_time = time.time()
    SILENCE_TIMEOUT = 1.5
    has_sent_audio = False  # ← 오디오 전송 여부 추적

    try:
        while True:
            try:
                item = await asyncio.wait_for(audio_queue.get(), timeout=0.1)
            except asyncio.TimeoutError:
                # ✅ 오디오를 보낸 적이 있을 때만 turn_complete 전송
                if has_sent_audio and time.time() - last_audio_time >= SILENCE_TIMEOUT:
                    print(f"Silence detected ({SILENCE_TIMEOUT}s), sending turn_complete")
                    await session.send_client_content(turns=None, turn_complete=True)
                    last_audio_time = time.time()
                    has_sent_audio = False  # Reset for next turn
                continue

            # ... (나머지 코드)

            # Send audio
            await session.send_realtime_input(
                media_chunks=[types.Blob(data=audio_data, mime_type="audio/pcm")]
            )
            
            send_count += 1
            has_sent_audio = True  # ← 오디오 전송 완료 표시
            last_audio_time = time.time()
```

---

## 📌 수정 체크리스트

### 필수 (지금 바로!)
- [ ] **버그 1**: `turns=[]` → `turns=None` 변경 (라인 192)
- [ ] **버그 2**: `has_sent_audio` 플래그 추가하여 오디오 전송 후에만 turn_complete 전송

### 완료됨 ✅
- [x] `gemini_client.py`: 침묵 감지 후 `turn_complete` 전송
- [x] `gemini_client.py`: `session.send()` → `session.send_realtime_input()` 변경

---

## 🔍 수정 후 예상 로그

```
Connected to Gemini Live API
Sent 10 audio chunks to API (2048 bytes each)
Sent 20 audio chunks to API (2048 bytes each)
Silence detected (1.5s), sending turn_complete  ← 오디오 보낸 후에만!
Response #1 received
   [TEXT] Part 0: 안녕하세요...
   [AUDIO] Part 1: 46080 bytes
```

---

## 📝 완료 보고

```bash
git add -A
git commit -m "fix: correct turn_complete params and add audio send check"
```

---

## 📚 참고: docs/REFERENCE.md

API 사용법 레퍼런스 문서가 추가되었습니다. 필요시 참고하세요.
