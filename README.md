# LiveNote 🎙️

**Real-time English to Korean Voice Translation for Zoom Calls**

Zoom 통화 실시간 영어→한국어 음성 번역 데스크톱 앱

## ⚠️ Important: S2ST Model Access

> **v0.5.0부터 Gemini S2ST (Speech-to-Speech Translation) 모델을 사용합니다.**
>
> `gemini-2.5-flash-s2st-exp-11-2025`는 **experimental 모델**로, 사용하려면 **Google Cloud 계정팀에 별도 승인 요청**이 필요합니다.
>
> - Vertex AI 프로젝트 설정 필요
> - Service Account 인증 필요
> - S2ST 모델 접근 권한 요청 필요
>
> 자세한 내용은 [Google Cloud Vertex AI Live API 문서](https://cloud.google.com/vertex-ai/generative-ai/docs/live-api/speech-to-speech-translation)를 참조하세요.

## 🚀 Features

- ⚡ **Real-time S2ST Translation**: Gemini S2ST 모델을 사용한 실시간 음성→음성 번역
- 🎯 **Full Duplex Streaming**: WebSocket 기반 양방향 실시간 스트리밍
- 🎙️ **Audio Source Selection**: Choose from virtual audio cables, WASAPI loopback, or any audio input
- 🖥️ **Live Display**: See translations on screen in real-time with auto-scroll
- 💾 **Auto-save**: Automatically save transcripts with timestamps
- 🌙 **Dark Mode UI**: Easy on the eyes during long meetings
- 🔄 **Smart Buffering**: 영어-한국어 쌍으로 동기화된 출력
- 🔁 **Auto Reconnection**: 세션 타임아웃 시 자동 재연결

## 🛠️ Tech Stack

- **Language**: Python 3.11+
- **GUI**: PyQt6
- **AI**: Gemini S2ST (Speech-to-Speech Translation) via Vertex AI Live API
- **Audio**: sounddevice + WASAPI
- **WebSocket**: websockets (Full Duplex streaming)

## 📦 Installation

```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/LiveNote.git
cd LiveNote

# Create virtual environment
python -m venv venv
venv\Scripts\activate  # Windows
# source venv/bin/activate  # macOS/Linux

# Install dependencies
pip install -r requirements.txt

# (Optional) Download Silero VAD model for intelligent segmentation
python scripts/download_vad_model.py
# 또는 수동 다운로드:
# https://github.com/snakers4/silero-vad/raw/master/src/silero_vad/data/silero_vad.onnx
# → models/silero_vad.onnx 에 저장
```

## ⚙️ Configuration

### Vertex AI Setup (Required for S2ST)

1. Create a Google Cloud project with billing enabled
2. Enable Vertex AI API
3. Create a Service Account with Vertex AI permissions
4. Download the Service Account key (JSON)
5. Place the key in `credentials/` folder
6. Update `config.yaml`:
   ```yaml
   translation:
     model: gemini-2.5-flash-s2st-exp-11-2025
     use_vertex_ai: true
     vertex_project: YOUR_PROJECT_ID
     vertex_location: us-central1
     service_account_key: credentials/YOUR_KEY.json
   ```

### Audio Source

Select your audio source (virtual audio cable recommended for Zoom)

## 📖 Usage

1. Start the application (run from project root): `python -m src.main`
2. Select audio source from dropdown
3. Click "Start" to begin translation
4. View real-time translations in the main window
5. Transcripts are automatically saved to `output/` folder

## 📁 Project Structure

```
LiveNote/
├── src/
│   ├── main.py              # Application entry point
│   ├── ui/                  # PyQt6 UI components
│   ├── audio/               # Audio capture modules
│   ├── translator/          # Gemini API integration
│   ├── config/              # Settings management
│   └── utils/               # Utility functions
├── docs/                    # Documentation
├── output/                  # Saved transcripts
└── requirements.txt
```

## 📋 Development

See [CLAUDE.md](CLAUDE.md) for project context and implementation details.
See [docs/REFERENCE.md](docs/REFERENCE.md) for Gemini Live API reference.

## 📄 License

MIT License

---

*Built with ❤️ using Gemini Native Audio API*
