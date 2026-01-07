# 🔴 FEEDBACK - Phase 6: 오디오 출력 + 세션 관리

> **작성일**: 2026-01-07  
> **상태**: 🔴 구현 필요  
> **대상**: Cline (Gemini)

---

## 📚 참조 문서

- **세션 관리**: https://ai.google.dev/gemini-api/docs/live-session?hl=ko
- **Live API 가이드**: https://ai.google.dev/gemini-api/docs/live-guide?hl=ko

---

## 🎯 구현할 기능

### Feature 1: 오디오 출력 장치 선택 + 볼륨 조절

**목적**: Gemini Native Audio 모델이 반환하는 음성 응답을 선택한 출력 장치로 재생

**UI 변경**:
```
┌─────────────────────────────────────────────────────────────────────┐
│ Audio Source: [▼ 스테레오 믹스]                                      │
│ Audio Output: [▼ 32UF10 - NVIDIA]  Volume: [━━━━○━━━] 50%  [🔇 Mute]│
│                                                                     │
│ [Start Translation]                                          [⚙️]   │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   Translation will appear here...                                   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

#### 1-1. 출력 장치 조회 메서드 추가

**파일**: `src/audio/device_manager.py`

```python
import sounddevice as sd

class DeviceManager:
    # ... existing methods ...
    
    @staticmethod
    def get_output_devices():
        """Get list of audio output devices."""
        devices = []
        for i, device in enumerate(sd.query_devices()):
            if device['max_output_channels'] > 0:
                devices.append({
                    'id': i,
                    'name': device['name'],
                    'channels': device['max_output_channels'],
                    'default_samplerate': device['default_samplerate']
                })
        return devices
```

---

#### 1-2. 오디오 재생 모듈 생성

**파일**: `src/audio/playback.py` (새로 생성)

```python
import sounddevice as sd
import numpy as np
import asyncio
from typing import Optional

class AudioPlayback:
    """Plays audio data through selected output device."""
    
    def __init__(self, device_id: Optional[int] = None, sample_rate: int = 24000):
        self.device_id = device_id
        self.sample_rate = sample_rate
        self.volume = 0.5  # 0.0 to 1.0
        self.muted = False
        self._audio_queue = asyncio.Queue()
        self._playback_task = None
    
    def set_device(self, device_id: int):
        """Set output device."""
        self.device_id = device_id
    
    def set_volume(self, volume: float):
        """Set volume (0.0 to 1.0)."""
        self.volume = max(0.0, min(1.0, volume))
    
    def set_muted(self, muted: bool):
        """Set mute state."""
        self.muted = muted
    
    def toggle_mute(self) -> bool:
        """Toggle mute and return new state."""
        self.muted = not self.muted
        return self.muted
    
    async def start(self):
        """Start playback loop."""
        self._playback_task = asyncio.create_task(self._playback_loop())
    
    async def stop(self):
        """Stop playback."""
        if self._playback_task:
            self._playback_task.cancel()
            try:
                await self._playback_task
            except asyncio.CancelledError:
                pass
    
    async def queue_audio(self, audio_data: bytes):
        """Add audio data to playback queue."""
        await self._audio_queue.put(audio_data)
    
    async def _playback_loop(self):
        """Continuously play queued audio."""
        try:
            while True:
                audio_data = await self._audio_queue.get()
                
                if self.muted or self.volume == 0:
                    continue  # Skip playback but consume queue
                
                try:
                    # Convert bytes to numpy array (assuming 16-bit PCM from Gemini)
                    audio_array = np.frombuffer(audio_data, dtype=np.int16)
                    # Normalize and apply volume
                    audio_float = audio_array.astype(np.float32) / 32768.0 * self.volume
                    
                    # Play audio (blocking but short chunks)
                    sd.play(audio_float, self.sample_rate, device=self.device_id)
                    sd.wait()  # Wait for playback to finish
                    
                except Exception as e:
                    print(f"Playback error: {e}")
                    
        except asyncio.CancelledError:
            pass
```

---

#### 1-3. UI에 출력 장치 선택 + 볼륨 조절 추가

**파일**: `src/ui/main_window.py`

**추가할 import**:
```python
from PyQt6.QtWidgets import QSlider, QComboBox
from src.audio.playback import AudioPlayback
from src.audio.device_manager import DeviceManager
```

**init에 추가**:
```python
self.audio_playback = AudioPlayback()
```

**init_ui()에 추가** (top_layout 아래에):
```python
# Output Device Row
output_layout = QHBoxLayout()

output_label = QLabel("Audio Output:")
output_label.setStyleSheet("color: #AAAAAA;")
output_layout.addWidget(output_label)

self.output_selector = QComboBox()
self.output_selector.setStyleSheet("background-color: #3E3E3E; color: white; padding: 5px;")
self._populate_output_devices()
self.output_selector.currentIndexChanged.connect(self._on_output_device_changed)
output_layout.addWidget(self.output_selector, 1)

volume_label = QLabel("Volume:")
volume_label.setStyleSheet("color: #AAAAAA;")
output_layout.addWidget(volume_label)

self.volume_slider = QSlider(Qt.Orientation.Horizontal)
self.volume_slider.setRange(0, 100)
self.volume_slider.setValue(50)
self.volume_slider.setFixedWidth(100)
self.volume_slider.valueChanged.connect(self._on_volume_changed)
output_layout.addWidget(self.volume_slider)

self.volume_value_label = QLabel("50%")
self.volume_value_label.setFixedWidth(40)
output_layout.addWidget(self.volume_value_label)

self.mute_btn = QPushButton("🔊")
self.mute_btn.setFixedWidth(30)
self.mute_btn.setStyleSheet("background-color: #3E3E3E; border-radius: 4px;")
self.mute_btn.clicked.connect(self._toggle_mute)
output_layout.addWidget(self.mute_btn)

layout.addLayout(output_layout)
```

**새 메서드 추가**:
```python
def _populate_output_devices(self):
    """Populate output device dropdown."""
    self.output_selector.clear()
    devices = DeviceManager.get_output_devices()
    for device in devices:
        self.output_selector.addItem(device['name'], device['id'])

def _on_output_device_changed(self, index):
    """Handle output device change."""
    device_id = self.output_selector.currentData()
    if device_id is not None:
        self.audio_playback.set_device(device_id)

def _on_volume_changed(self, value):
    """Handle volume slider change."""
    self.volume_value_label.setText(f"{value}%")
    self.audio_playback.set_volume(value / 100.0)

def _toggle_mute(self):
    """Toggle mute state."""
    muted = self.audio_playback.toggle_mute()
    self.mute_btn.setText("🔇" if muted else "🔊")
```

**process_audio_stream() 수정**:
```python
elif item_type == "audio":
    # Play audio through selected output device
    await self.audio_playback.queue_audio(data)
```

**start_translation() 수정** (await self.audio_capture.start() 다음에):
```python
# Start audio playback
await self.audio_playback.start()
```

**stop_translation() 수정**:
```python
# Stop audio playback
await self.audio_playback.stop()
```

---

### Feature 2: 세션 관리 (15분 제한 해결)

**목적**: Live API 세션이 15분에 만료되므로, 장시간 미팅(30분~1시간)을 지원하기 위해 자동 재연결

**참조**: https://ai.google.dev/gemini-api/docs/live-session?hl=ko

---

#### 2-1. 세션 관리 로직 추가

**파일**: `src/translator/gemini_client.py`

```python
import time

class GeminiClient:
    SESSION_TIMEOUT = 14 * 60  # 14분 (15분 제한 전 여유)
    
    def __init__(self):
        # ... existing code ...
        self.session_start_time = None
        self._reconnecting = False
    
    async def stream_audio(self, audio_queue):
        """
        Connects to Live API and streams audio from the queue.
        Automatically reconnects before session timeout.
        """
        while self.is_connected:
            try:
                async for item in self._stream_audio_session(audio_queue):
                    yield item
            except SessionExpiredError:
                print("Session expired, reconnecting...")
                await asyncio.sleep(0.5)
                continue
            except Exception as e:
                if not self._reconnecting:
                    print(f"Stream error: {e}")
                    raise
    
    async def _stream_audio_session(self, audio_queue):
        """Single session stream with timeout monitoring."""
        if not self.client:
            print("Client not initialized")
            return

        # ... config setup (existing code) ...

        try:
            print(f"Connecting to Live API with model: {self.model_name}...")
            async with self.client.aio.live.connect(model=self.model_name, config=config) as session:
                self.session = session
                self.session_start_time = time.time()
                print("Connected to Gemini Live API")
                
                # Start tasks
                send_task = asyncio.create_task(self._send_audio_loop(session, audio_queue))
                timeout_task = asyncio.create_task(self._session_timeout_monitor())
                
                try:
                    while True:
                        async for response in session.receive():
                            if response.server_content and response.server_content.model_turn:
                                for part in response.server_content.model_turn.parts:
                                    if part.text:
                                        yield ("text", part.text)
                                    elif part.inline_data and part.inline_data.mime_type.startswith("audio/"):
                                        yield ("audio", part.inline_data.data)
                except asyncio.CancelledError:
                    print("Receive loop cancelled")
                finally:
                    send_task.cancel()
                    timeout_task.cancel()
                    try:
                        await send_task
                        await timeout_task
                    except asyncio.CancelledError:
                        pass

        except Exception as e:
            print(f"Live API Connection Error: {e}")
            traceback.print_exc()
            raise
    
    async def _session_timeout_monitor(self):
        """Monitor session timeout and trigger reconnection."""
        try:
            while True:
                await asyncio.sleep(30)  # Check every 30 seconds
                
                if self.session_start_time:
                    elapsed = time.time() - self.session_start_time
                    remaining = self.SESSION_TIMEOUT - elapsed
                    
                    if remaining < 60:  # Less than 1 minute remaining
                        print(f"Session timeout in {remaining:.0f}s, preparing reconnection...")
                    
                    if elapsed >= self.SESSION_TIMEOUT:
                        print("Session timeout reached, triggering reconnection...")
                        self._reconnecting = True
                        raise SessionExpiredError("Session timeout")
                        
        except asyncio.CancelledError:
            pass

class SessionExpiredError(Exception):
    """Raised when session needs to be refreshed."""
    pass
```

---

#### 2-2. 세션 상태 UI 표시 (선택)

**파일**: `src/ui/main_window.py`

status_bar에 세션 남은 시간 표시:

```python
# init에 추가
self.session_timer = QTimer()
self.session_timer.timeout.connect(self._update_session_status)

# start_translation()에 추가
self.session_timer.start(10000)  # Update every 10 seconds

# stop_translation()에 추가
self.session_timer.stop()

# 새 메서드
def _update_session_status(self):
    """Update session time remaining in status bar."""
    if self.gemini_client and self.gemini_client.session_start_time:
        elapsed = time.time() - self.gemini_client.session_start_time
        remaining = (14 * 60) - elapsed  # 14 minutes
        
        if remaining > 0:
            minutes = int(remaining // 60)
            seconds = int(remaining % 60)
            self.status_bar.showMessage(f"Translating... (Session: {minutes}:{seconds:02d} remaining)")
        else:
            self.status_bar.showMessage("Translating... (Reconnecting...)")
```

---

## 📌 구현 체크리스트

### Feature 1: 오디오 출력 + 볼륨 조절
- [ ] `device_manager.py`: `get_output_devices()` 메서드 추가
- [ ] `audio/playback.py`: 새 파일 생성 - 오디오 재생 클래스
- [ ] `main_window.py`: 출력 장치 드롭다운 추가
- [ ] `main_window.py`: 볼륨 슬라이더 추가
- [ ] `main_window.py`: 뮤트 버튼 추가
- [ ] `main_window.py`: process_audio_stream()에서 오디오 재생

### Feature 2: 세션 관리
- [ ] `gemini_client.py`: `SessionExpiredError` 예외 클래스 추가
- [ ] `gemini_client.py`: `_session_timeout_monitor()` 메서드 추가
- [ ] `gemini_client.py`: `stream_audio()`에 자동 재연결 로직 추가
- [ ] (선택) `main_window.py`: 세션 남은 시간 status bar 표시

---

## 🔍 테스트 방법

### 오디오 출력 테스트
1. 앱 실행: `python -m src.main`
2. Audio Output 드롭다운에서 출력 장치 선택 (예: 32UF10)
3. 볼륨 슬라이더 조절
4. Start Translation → 영어 말하기 → 한국어 음성 출력 확인
5. 뮤트 버튼 클릭 → 음성 출력 안 됨 확인

### 세션 관리 테스트
1. Start Translation
2. 14분 이상 대기 (또는 테스트용으로 SESSION_TIMEOUT을 60초로 설정)
3. 콘솔에서 "Session timeout reached, triggering reconnection..." 메시지 확인
4. 자동 재연결 후 번역 계속 작동 확인

---

## 📝 완료 보고

구현 완료 후 `SESSION_LOG.md`에 기록:

```markdown
## Session: Phase 6 - Audio Output & Session Management
- Added: Audio output device selector
- Added: Volume slider + mute button
- Added: Auto-reconnection for 15-minute session limit
- Tested: [테스트 결과]
```

```bash
git add -A
git commit -m "feat: audio output control and session management"
```
