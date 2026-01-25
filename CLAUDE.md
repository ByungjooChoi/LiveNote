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
│   │   ├── gemini_client.py    # Gemini Live API WebSocket client
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

### Gemini Live API
- Model: `gemini-2.5-flash-native-audio-preview-12-2025`
- Input: PCM 16kHz 16-bit mono
- Output: PCM 24kHz 16-bit mono + text
- Session timeout: 15 minutes (auto-reconnect at 14 min)
- Must send `turn_complete=True` after silence to trigger response

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
