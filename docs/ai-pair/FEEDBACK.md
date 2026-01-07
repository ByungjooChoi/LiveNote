# 🔴 FEEDBACK - Phase 7: 디버깅 & UX 개선

> **작성일**: 2026-01-07  
> **상태**: 🔴 구현 필요  
> **대상**: Cline (Gemini)

---

## 🎯 문제점

번역 결과가 나오지 않을 때 원인을 파악하기 어려움:
1. 사운드 소스를 잘못 선택했는지?
2. 오디오가 캡처는 되는데 API로 전송이 안 되는지?
3. API로 전송은 했는데 응답이 안 오는지?

---

## 📋 구현할 기능

### Feature 1: 오디오 레벨 미터 (VU Meter)

**목적**: 입력 오디오가 실제로 들어오는지 시각적으로 확인

**UI**:
```
Audio Source: [▼ 스테레오 믹스]  [████████░░░░░░░░] 52dB
```

**구현 방법**:
1. `capture.py`에서 이미 RMS를 계산하고 있음 (VAD용)
2. RMS 값을 UI로 전달하여 프로그레스바로 표시
3. 소리가 없으면 0%, 소리가 크면 100%

---

### Feature 2: 상태 인디케이터

**목적**: 현재 어느 단계에서 문제가 발생하는지 파악

**UI**:
```
Status: 🎤 Capturing → 📤 Sending → 📥 Receiving → ✅ Translating
```

**상태 종류**:
- `⏸️ Ready` - 대기 중
- `🎤 Capturing` - 오디오 캡처 중 (레벨 표시)
- `📤 Sending` - API로 전송 중
- `📥 Receiving` - 응답 대기 중
- `✅ Translating` - 번역 결과 수신 중
- `⚠️ No Audio` - 오디오 입력 없음 (5초 이상 무음)
- `❌ Error` - 에러 발생

---

### Feature 3: 실시간 오디오 미리보기 (Audio Preview)

**목적**: 사운드 소스 선택 시 해당 소스에서 오디오가 들어오는지 즉시 확인

**동작**:
1. 사운드 소스 드롭다운 옆에 "Preview" 버튼 추가
2. Preview 클릭 → 해당 소스에서 2초간 오디오 캡처 → 레벨 미터 표시
3. 오디오가 감지되면 ✅, 없으면 ❌ 표시

---

### Feature 4: 자동 소스 감지 (선택)

**목적**: 사용자가 말하거나 시스템 소리가 나면 자동으로 번역 시작

**동작**:
- Start Translation 클릭 후 5초간 무음이면 경고 표시
- "No audio detected. Please check your audio source."

---

## 🔧 구현 상세

### 1-1. capture.py 수정 - RMS 콜백 추가

**파일**: `src/audio/capture.py`

```python
class AudioCapture:
    def __init__(self, device_id=None, sample_rate=16000, chunk_size=1024, on_level_update=None):
        # ... existing code ...
        self.on_level_update = on_level_update  # Callback for audio level updates
    
    def _audio_callback(self, indata, frames, time, status):
        # ... existing code ...
        rms = np.sqrt(np.mean(indata**2))
        db = 20 * np.log10(rms + 1e-10)  # Convert to dB
        
        # Call level update callback
        if self.on_level_update:
            # Normalize to 0-100 range (assuming -60dB to 0dB range)
            level = max(0, min(100, (db + 60) * 100 / 60))
            self.on_level_update(level)
        
        # ... rest of existing code ...
```

---

### 1-2. main_window.py - 레벨 미터 UI 추가

```python
from PyQt6.QtWidgets import QProgressBar

# In init_ui(), after audio_selector:
self.level_meter = QProgressBar()
self.level_meter.setRange(0, 100)
self.level_meter.setValue(0)
self.level_meter.setTextVisible(False)
self.level_meter.setFixedHeight(10)
self.level_meter.setStyleSheet("""
    QProgressBar { background-color: #2D2D2D; border: none; border-radius: 5px; }
    QProgressBar::chunk { background-color: #00FF00; border-radius: 5px; }
""")

# Add to input layout
input_layout.addWidget(self.level_meter)
```

---

### 1-3. 상태 인디케이터 추가

```python
# In init_ui():
self.status_indicator = QLabel("⏸️ Ready")
self.status_indicator.setStyleSheet("color: #AAAAAA; font-size: 12px;")

# Methods to update status:
def _update_status(self, status_code, message=None):
    status_map = {
        "ready": "⏸️ Ready",
        "capturing": "🎤 Capturing",
        "sending": "📤 Sending",
        "receiving": "📥 Receiving",
        "translating": "✅ Translating",
        "no_audio": "⚠️ No Audio",
        "error": "❌ Error"
    }
    
    text = status_map.get(status_code, status_code)
    if message:
        text += f" - {message}"
    
    self.status_indicator.setText(text)
    
    # Update color based on status
    colors = {
        "ready": "#AAAAAA",
        "capturing": "#00AAFF",
        "sending": "#FFAA00",
        "receiving": "#00FFAA",
        "translating": "#00FF00",
        "no_audio": "#FFAA00",
        "error": "#FF5555"
    }
    self.status_indicator.setStyleSheet(f"color: {colors.get(status_code, '#FFFFFF')}; font-size: 12px;")
```

---

### 1-4. gemini_client.py - 상태 콜백 추가

```python
class GeminiClient:
    def __init__(self, on_status_change=None):
        # ... existing code ...
        self.on_status_change = on_status_change
    
    def _emit_status(self, status, message=None):
        if self.on_status_change:
            self.on_status_change(status, message)
    
    async def _send_audio_loop(self, session, audio_queue):
        try:
            while True:
                item = await audio_queue.get()
                # ... existing code ...
                
                self._emit_status("sending")  # 전송 중
                await session.send(...)
                
        except Exception as e:
            self._emit_status("error", str(e))
    
    # In receive loop:
    async for response in session.receive():
        self._emit_status("receiving")  # 수신 중
        if response.server_content and response.server_content.model_turn:
            self._emit_status("translating")  # 번역 결과 수신
            # ... yield text/audio ...
```

---

### 1-5. 무음 감지 경고

```python
# In main_window.py:
class MainWindow:
    def __init__(self):
        # ... existing code ...
        self.last_audio_time = None
        self.silence_check_timer = QTimer()
        self.silence_check_timer.timeout.connect(self._check_silence)
    
    def _on_audio_level_update(self, level):
        """Called when audio level changes."""
        self.level_meter.setValue(int(level))
        
        # Update last audio time if level is significant
        if level > 5:  # Threshold
            self.last_audio_time = time.time()
            self._update_status("capturing")
    
    def _check_silence(self):
        """Check if no audio for too long."""
        if self.last_audio_time and self.is_running:
            silence_duration = time.time() - self.last_audio_time
            if silence_duration > 5:  # 5 seconds of silence
                self._update_status("no_audio", "Check your audio source")
    
    async def start_translation(self):
        # ... existing code ...
        self.last_audio_time = time.time()
        self.silence_check_timer.start(1000)  # Check every second
    
    async def stop_translation(self):
        # ... existing code ...
        self.silence_check_timer.stop()
```

---

### 1-6. Audio Preview 버튼 (선택)

```python
# In init_ui(), next to audio_selector:
self.preview_btn = QPushButton("🔊 Preview")
self.preview_btn.setFixedWidth(80)
self.preview_btn.clicked.connect(self._preview_audio_source)

async def _preview_audio_source(self):
    """Preview the selected audio source for 2 seconds."""
    device_id = self.audio_selector.get_selected_device_id()
    if device_id is None:
        return
    
    self.preview_btn.setEnabled(False)
    self.preview_btn.setText("Testing...")
    
    max_level = 0
    
    def on_level(level):
        nonlocal max_level
        max_level = max(max_level, level)
        self.level_meter.setValue(int(level))
    
    # Create temporary capture
    temp_capture = AudioCapture(device_id=device_id, on_level_update=on_level)
    await temp_capture.start()
    
    await asyncio.sleep(2)  # Capture for 2 seconds
    
    temp_capture.stop()
    
    # Show result
    if max_level > 10:
        self.preview_btn.setText("✅ Detected")
    else:
        self.preview_btn.setText("❌ No Audio")
    
    await asyncio.sleep(1)
    self.preview_btn.setText("🔊 Preview")
    self.preview_btn.setEnabled(True)
```

---

## 📌 구현 체크리스트

### 필수
- [ ] `capture.py`: `on_level_update` 콜백 추가
- [ ] `main_window.py`: 레벨 미터 (QProgressBar) 추가
- [ ] `main_window.py`: 상태 인디케이터 추가
- [ ] `main_window.py`: 무음 감지 경고 추가

### 선택
- [ ] `main_window.py`: Audio Preview 버튼
- [ ] `gemini_client.py`: 상태 콜백 추가

---

## 🔍 예상 UI

```
┌─────────────────────────────────────────────────────────────────────┐
│ Audio Source: [▼ 스테레오 믹스]  [████████░░░░░░░░] [🔊 Preview]    │
│ Audio Output: [▼ 32UF10 - NVIDIA]  [━━━○━] 50%  [🔊]               │
│                                                                     │
│ Status: 🎤 Capturing                                                │
│                                                                     │
│ [Start Translation]                                          [⚙️]   │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   안녕하세요, 이것은 테스트입니다.                                    │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 📝 완료 보고

구현 완료 후 `SESSION_LOG.md`에 기록:

```markdown
## Session: Phase 7 - Debugging & UX
- Added: Audio level meter
- Added: Status indicator
- Added: Silence detection warning
- Added: Audio preview button (optional)
- Tested: [테스트 결과]
```

```bash
git add -A
git commit -m "feat: audio level meter and status indicators for debugging"
```
