# LiveNote 🎙️

**Real-time English to Korean Voice Translation for Zoom Calls**

Zoom 통화 실시간 영어→한국어 음성 번역 데스크톱 앱

## 🚀 Features

- ⚡ **Real-time Translation**: Instantly translate English speech to Korean using Gemini 2.5 Flash Native Audio
- 🎙️ **Audio Source Selection**: Choose from virtual audio cables, WASAPI loopback, or any audio input
- 🖥️ **Live Display**: See translations on screen in real-time with auto-scroll
- 💾 **Auto-save**: Automatically save transcripts with timestamps
- 🌙 **Dark Mode UI**: Easy on the eyes during long meetings

## 🛠️ Tech Stack

- **Language**: Python 3.11+
- **GUI**: PyQt6
- **AI**: Google Gemini 2.5 Flash Native Audio (Live API)
- **Audio**: sounddevice + WASAPI

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
```

## ⚙️ Configuration

1. Get your Gemini API key from [Google AI Studio](https://aistudio.google.com/)
2. Run the app and enter your API key in Settings
3. Select your audio source (virtual audio cable recommended for Zoom)

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
