# 🔴 FEEDBACK - 심각한 버그 수정 + 디버깅 강화

> **작성일**: 2026-01-08
> **상태**: 🔴 긴급 수정 필요
> **대상**: Cline (Gemini)

---

## 🚨 심각한 버그 (번역이 안 나오는 원인)

### Bug 0: Qt 스레드 충돌 - UI 업데이트가 백그라운드 스레드에서 실행됨

**증상**: 콘솔에 `QWidget::repaint: Recursive repaint detected` 경고 출력

**원인**: `capture.py`의 `_callback()` 함수는 **sounddevice의 백그라운드 스레드**에서 실행됩니다.
여기서 `self.on_level_update(level)`을 직접 호출하면, `main_window.py`의 `_on_audio_level_update()`가 호출되고,
이것이 `self.level_meter.setValue()`로 UI를 업데이트합니다.

**문제**: PyQt에서 UI 업데이트는 **반드시 메인 스레드**에서 이루어져야 합니다!

**파일**: `src/audio/capture.py`
**라인**: 42-47

**현재 코드**:
```python
if self.on_level_update:
    db = 20 * np.log10(rms + 1e-10)
    level = max(0, min(100, int((db + 60) * 100 / 60)))
    self.on_level_update(level)  # ← 백그라운드 스레드에서 직접 호출!
```

**수정할 코드**:
```python
if self.on_level_update:
    db = 20 * np.log10(rms + 1e-10)
    level = max(0, min(100, int((db + 60) * 100 / 60)))
    # Must call on main thread for PyQt UI updates
    self.loop.call_soon_threadsafe(self.on_level_update, level)
```

---

### Bug 0.5: VAD 필터링이 너무 엄격할 수 있음 (디버깅 필요)

**잠재적 문제**: 오디오가 `silence_threshold` (0.01) 미만이면 큐에 아무것도 안 들어감

**파일**: `src/audio/capture.py`
**라인**: 50-52

**현재 코드**:
```python
if rms >= self.silence_threshold:  # 0.01
    self.loop.call_soon_threadsafe(self.queue.put_nowait, (audio_data, rms))
```

**디버깅 로그 추가**:
```python
# Add debug counter (temporary)
if not hasattr(self, '_debug_count'):
    self._debug_count = 0
    self._queue_count = 0

self._debug_count += 1
if rms >= self.silence_threshold:
    self._queue_count += 1
    self.loop.call_soon_threadsafe(self.queue.put_nowait, (audio_data, rms))

# Log every 100 callbacks
if self._debug_count % 100 == 0:
    print(f"🎤 Audio callback: {self._debug_count} calls, {self._queue_count} queued, last RMS: {rms:.4f}")
```

**테스트 후 threshold가 문제면**:
- `silence_threshold`를 0.001 또는 0.005로 낮추거나
- 일시적으로 VAD를 비활성화: `if True:  # rms >= self.silence_threshold`

---

## 🐛 기타 버그

### Bug 1: 상태 인디케이터가 너무 일찍 "Translating" 표시

**현재 동작**:
- Start Translation 클릭 → 바로 "✅ Translating" 표시
- 실제 번역 데이터가 없어도 표시됨

**올바른 동작**:
- `🎤 Capturing` → 오디오 캡처 중 (데이터 전송 중)
- `📥 Receiving` → API 응답 대기 중
- `✅ Translating` → **실제 텍스트가 도착했을 때만**

**파일**: `src/ui/main_window.py`  
**라인**: 342

**현재 코드**:
```python
async def process_audio_stream(self):
    try:
        async for item in self.gemini_client.stream_audio(self.audio_capture.queue):
            self._update_status("translating")  # ← 문제: 매 응답마다 호출
```

**수정할 코드**:
```python
async def process_audio_stream(self):
    try:
        async for item in self.gemini_client.stream_audio(self.audio_capture.queue):
            # Don't update status here - only when we actually get text
            
            text_to_display = ""
            
            if isinstance(item, tuple):
                item_type, data = item
                if item_type == "text":
                    text_to_display = data
                    self._update_status("translating")  # ← 텍스트 받았을 때만!
                elif item_type == "audio":
                    await self.audio_playback.queue_audio(data)
                    continue
            else:
                text_to_display = item
                self._update_status("translating")  # ← 텍스트 받았을 때만!
```

---

### Bug 2: 더 세분화된 상태 표시 필요

**추가할 상태**:
- `📤 Sending` → 오디오를 API로 전송 중
- `📥 Waiting` → API 응답 대기 중

**gemini_client.py 수정**:

```python
class GeminiClient:
    def __init__(self, on_status_change=None):
        # ... existing code ...
        self.on_status_change = on_status_change  # 콜백 추가
    
    def _emit_status(self, status, message=None):
        if self.on_status_change:
            self.on_status_change(status, message)
```

**_send_audio_loop()에 상태 추가**:
```python
async def _send_audio_loop(self, session, audio_queue):
    try:
        while True:
            item = await audio_queue.get()
            # ... existing code ...
            
            self._emit_status("sending")  # 전송 중 상태
            await session.send(...)
```

**main_window.py에서 콜백 연결**:
```python
# start_translation()에서:
self.gemini_client = GeminiClient(on_status_change=self._on_gemini_status)

def _on_gemini_status(self, status, message=None):
    self._update_status(status, message)
```

---

## 🔍 디버깅 강화

### 콘솔 로그 추가

번역이 안 나오는 원인을 파악하기 위해 더 자세한 로그 추가:

**gemini_client.py**:

```python
async def _stream_audio_session(self, audio_queue):
    # ... config setup ...
    
    try:
        print(f"Connecting to Live API with model: {self.model_name}...")
        async with self.client.aio.live.connect(model=self.model_name, config=config) as session:
            self.session = session
            self.session_start_time = time.time()
            print("✅ Connected to Gemini Live API")
            
            # ... tasks setup ...
            
            try:
                response_count = 0
                while True:
                    async for response in session.receive():
                        response_count += 1
                        print(f"📥 Response #{response_count} received")
                        
                        if response.server_content:
                            if response.server_content.model_turn:
                                parts = response.server_content.model_turn.parts
                                print(f"   Parts count: {len(parts)}")
                                for i, part in enumerate(parts):
                                    if part.text:
                                        print(f"   [TEXT] Part {i}: {part.text[:50]}...")
                                        yield ("text", part.text)
                                    elif part.inline_data:
                                        print(f"   [AUDIO] Part {i}: {len(part.inline_data.data)} bytes")
                                        yield ("audio", part.inline_data.data)
                            else:
                                print(f"   No model_turn in response")
                        else:
                            print(f"   No server_content in response")
```

**_send_audio_loop()에 로그 추가**:
```python
async def _send_audio_loop(self, session, audio_queue):
    send_count = 0
    try:
        while True:
            item = await audio_queue.get()
            # ... processing ...
            
            send_count += 1
            if send_count % 10 == 0:  # 10개마다 로그
                print(f"📤 Sent {send_count} audio chunks")
            
            await session.send(...)
```

---

## 📌 수정 체크리스트 (우선순위 순)

### 🚨 긴급 - 심각한 버그 (반드시 수정)
- [ ] **Bug 0**: `capture.py` - `on_level_update`를 `loop.call_soon_threadsafe()`로 호출
- [ ] **Bug 0.5**: `capture.py` - 오디오 캡처 디버깅 로그 추가

### 디버깅 로그 (문제 원인 파악용)
- [ ] `gemini_client.py`: 응답 수신 시 로그 추가 (`📥 Response #N received`)
- [ ] `gemini_client.py`: 오디오 전송 카운트 로그 추가 (`📤 Sent N audio chunks`)
- [ ] `capture.py`: 오디오 큐 삽입 로그 추가 (`🎤 Audio callback: N calls, M queued`)

### 기타 버그
- [ ] **Bug 1**: `main_window.py` - "Translating" 상태를 텍스트 수신 시에만 표시

### 선택 사항 (나중에)
- [ ] `gemini_client.py`: `on_status_change` 콜백 추가
- [ ] `main_window.py`: 콜백 연결

---

## 🔍 테스트 방법

1. **앱 실행**: `python -m src.main`
2. **콘솔에서 확인할 로그**:
   ```
   ✅ Connected to Gemini Live API
   🎤 Audio callback: 100 calls, 85 queued, last RMS: 0.0234  ← 오디오 캡처 확인
   📤 Sent 10 audio chunks  ← API로 전송 확인
   📥 Response #1 received  ← API 응답 확인
      Parts count: 2
      [TEXT] Part 0: 안녕하세요...
      [AUDIO] Part 1: 4096 bytes
   ```
3. **Qt 경고 확인**:
   - `QWidget::repaint: Recursive repaint detected` 경고가 **사라져야** 함
4. **상태 인디케이터 확인**:
   - Start → `🎤 Capturing` (오디오 입력 있을 때)
   - 텍스트 수신 → `✅ Translating`

---

## ⚠️ 문제 진단 가이드

### 시나리오 1: `🎤 Audio callback` 로그가 안 나옴
→ 마이크가 제대로 선택되지 않았거나 sounddevice 문제

### 시나리오 2: `queued: 0` (아무것도 큐에 안 들어감)
→ `silence_threshold`가 너무 높음 → 0.001로 낮추기

### 시나리오 3: `📤 Sent` 로그가 안 나옴
→ 큐에서 데이터를 못 가져오고 있음 → gemini_client 문제

### 시나리오 4: `📥 Response` 로그가 안 나옴
→ API에서 응답이 안 옴 → 오디오 포맷/모델 문제

### 시나리오 5: `No model_turn in response` 또는 `No server_content`
→ API 응답 형식 문제 → 응답 객체 전체를 로깅해서 확인

---

## 📝 완료 보고

```bash
git add -A
git commit -m "fix: Qt thread safety and add comprehensive debugging logs"
```
