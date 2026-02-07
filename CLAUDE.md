# LiveNote - Project Context for Claude

## Project Overview

**LiveNote** is a real-time English to Korean voice translation desktop application for Zoom calls.
It captures audio from Zoom (via virtual audio cable or WASAPI loopback), sends it to Google Gemini Live API for translation, and displays the Korean translation in real-time.

## Tech Stack

- **Language**: Python 3.11+
- **GUI**: PyQt6 with qasync for async integration
- **AI**: Google Gemini 2.5 Flash Native Audio (Live API via WebSocket)
- **Audio**: sounddevice (input/output), numpy for audio processing
- **Config**: YAML for settings, environment variables for API key

## Project Structure

```
livenote/
├── src/
│   ├── main.py                 # App entry point (qasync event loop)
│   ├── audio/
│   │   ├── capture.py          # Real-time audio capture with VAD
│   │   ├── device_manager.py   # Input/output device enumeration
│   │   └── playback.py         # Audio playback for TTS output
│   ├── config/
│   │   ├── settings_manager.py # YAML config management
│   │   └── secure_storage.py   # API key storage (env var)
│   ├── translator/
│   │   ├── gemini_client.py    # Gemini generateContent API client
│   │   ├── live_api_client.py  # S2ST Live API Full Duplex client
│   │   └── model_fetcher.py    # Model list retrieval
│   ├── ui/
│   │   ├── main_window.py      # Main UI (dark mode)
│   │   ├── settings_dialog.py  # API key & model settings
│   │   └── audio_selector.py   # Audio device selector widget
│   └── utils/
│       └── file_writer.py      # Transcript file saving
├── tests/
│   ├── test_audio_stream.py
│   └── test_live_api.py
├── docs/
│   └── REFERENCE.md            # Gemini Live API reference
├── config.yaml                 # Default settings
├── requirements.txt
└── README.md
```

## Key Implementation Details

### Audio Flow
1. `AudioCapture` captures audio at 16kHz mono from selected device
2. VAD (Voice Activity Detection) filters silence (threshold-based)
3. Audio chunks are put into an asyncio queue
4. `GeminiClient` sends audio to Live API via WebSocket
5. Responses (text + audio) are yielded back to UI
6. `AudioPlayback` plays TTS audio output at 24kHz

### Gemini API 모드

**Standard Mode (generateContent)**
- Model: `gemini-2.5-flash`
- 방식: REST API, VAD 기반 세그멘테이션
- 입력: WAV (16kHz 16-bit mono)
- 출력: JSON (transcript, translation)

**S2ST Mode (Live API Full Duplex)**
- Model: `gemini-2.5-flash-s2st-exp-11-2025`
- 방식: WebSocket, 양방향 스트리밍
- 입력: PCM 16kHz 16-bit mono (연속 스트림)
- 출력: `input_transcription` (원문) + `output_transcription` (번역)
- 특징: VAD 불필요, Full Duplex (입출력 동시)
- 주의: Allowlist 승인 필요

### Audio Format Conversion
```python
# float32 (-1.0 to 1.0) to int16 (-32768 to 32767)
audio_int16 = (audio_float32 * 32767).astype(np.int16)
```

### UI
- Dark mode theme (#1E1E1E background)
- Real-time level meter
- Status indicator (Capturing/Sending/Receiving/Translating)
- Audio preview button
- Volume control and mute

## Running the App

```bash
# From project root
cd livenote
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
python -m src.main
```

## Known Issues / TODOs

1. **Microphone selection**: User must select the correct audio device
2. **Thought filtering**: API sometimes returns internal "thought" responses that should be skipped
3. **Session reconnection**: Auto-reconnect works but may have brief interruption
4. **Text output**: When using Native Audio model with `response_modalities=["AUDIO"]`, text may not appear in UI

## API Reference

See `docs/REFERENCE.md` for detailed Gemini Live API documentation.

## Development Notes

- All code comments should be in English
- Use `asyncio` and `qasync` for async operations
- Follow existing code style (type hints encouraged)
- Test with `pytest` when applicable

## 📋 필수 작업 (Claude 자동 수행)

### Changelog 업데이트
**코드 변경 시 반드시 `CHANGELOG.md` 업데이트:**
- 새 기능 추가 시: 새 버전 섹션 생성 (v0.X.0)
- 버그 수정 시: 해당 버전의 "Fixes" 섹션에 추가
- 형식: 기존 changelog 스타일 따르기 (표, 코드 블록 등)

### 업데이트 항목
1. **핵심 기능**: 무엇이 바뀌었는지 한 줄 요약
2. **변경 파일**: 수정된 파일 목록과 변경 내용
3. **사용 방법**: 새 기능 사용법 (해당 시)
4. **주의사항**: 알려진 제한사항이나 요구사항
