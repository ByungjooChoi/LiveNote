import asyncio
import time
from PyQt6.QtWidgets import (QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, 
                             QTextEdit, QPushButton, QLabel, QStatusBar, QSlider, QComboBox, QProgressBar)
from PyQt6.QtCore import Qt, QTimer
from qasync import asyncSlot

from src.ui.settings_dialog import SettingsDialog
from src.ui.audio_selector import AudioSelector
from src.audio.capture import AudioCapture
from src.translator.gemini_client import GeminiClient
from src.config.secure_storage import SecureStorage
from src.utils.file_writer import FileWriter
from src.config.settings_manager import settings
from src.audio.playback import AudioPlayback
from src.audio.device_manager import DeviceManager

class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("LiveNote - AI Translator")
        self.resize(800, 600)
        self.setStyleSheet("background-color: #1E1E1E; color: #FFFFFF;")
        
        self.is_running = False
        self.audio_capture = None
        self.gemini_client = GeminiClient()
        self.file_writer = FileWriter()
        self.process_task = None
        self.audio_playback = AudioPlayback()
        
        self.last_audio_time = None
        self.silence_check_timer = QTimer()
        self.silence_check_timer.timeout.connect(self._check_silence)
        
        self.init_ui()
        
        # Check API Key on startup
        if not SecureStorage.get_api_key():
            self.open_settings()

    def init_ui(self):
        central_widget = QWidget()
        self.setCentralWidget(central_widget)
        layout = QVBoxLayout(central_widget)
        
        # 1. Input Source & Level Meter
        input_layout = QHBoxLayout()
        # AudioSelector includes label and combo
        self.audio_selector = AudioSelector()
        input_layout.addWidget(self.audio_selector)
        
        # Level Meter
        self.level_meter = QProgressBar()
        self.level_meter.setRange(0, 100)
        self.level_meter.setValue(0)
        self.level_meter.setTextVisible(False)
        self.level_meter.setFixedHeight(10)
        self.level_meter.setStyleSheet("""
            QProgressBar { background-color: #2D2D2D; border: none; border-radius: 5px; }
            QProgressBar::chunk { background-color: #00FF00; border-radius: 5px; }
        """)
        input_layout.addWidget(self.level_meter)
        
        # Preview Button
        self.preview_btn = QPushButton("🔊 Preview")
        self.preview_btn.setFixedWidth(80)
        self.preview_btn.setStyleSheet("background-color: #3E3E3E; border-radius: 4px;")
        self.preview_btn.clicked.connect(self._preview_audio_source)
        input_layout.addWidget(self.preview_btn)
        
        layout.addLayout(input_layout)

        # 2. Output Device & Volume
        output_layout = QHBoxLayout()

        output_label = QLabel("Audio Output:")
        output_label.setStyleSheet("color: #AAAAAA;")
        output_layout.addWidget(output_label)

        self.output_selector = QComboBox()
        self.output_selector.setStyleSheet("background-color: #3E3E3E; color: white; padding: 5px;")
        # Populate later
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
        
        # 3. Status Indicator
        self.status_indicator = QLabel("⏸️ Ready")
        self.status_indicator.setStyleSheet("color: #AAAAAA; font-size: 14px; font-weight: bold; margin: 5px 0;")
        layout.addWidget(self.status_indicator)
        
        # 4. Control Buttons
        btn_layout = QHBoxLayout()
        
        self.start_btn = QPushButton("Start Translation")
        self.start_btn.setStyleSheet("""
            QPushButton { background-color: #007ACC; color: white; padding: 10px 20px; border-radius: 4px; border: none; font-weight: bold; font-size: 14px; }
            QPushButton:hover { background-color: #0098FF; }
            QPushButton:checked { background-color: #FF5555; }
        """)
        self.start_btn.setCheckable(True)
        self.start_btn.clicked.connect(self.toggle_translation)
        btn_layout.addWidget(self.start_btn, 1)
        
        self.settings_btn = QPushButton("⚙️")
        self.settings_btn.setFixedSize(40, 40)
        self.settings_btn.setStyleSheet("background-color: #3E3E3E; border-radius: 4px; border: none; font-size: 18px;")
        self.settings_btn.clicked.connect(self.open_settings)
        btn_layout.addWidget(self.settings_btn)
        
        layout.addLayout(btn_layout)
        
        # Populate output devices
        self._populate_output_devices()
        
        # Text Area
        self.text_area = QTextEdit()
        self.text_area.setReadOnly(True)
        self.text_area.setStyleSheet("""
            QTextEdit { background-color: #2D2D2D; color: #FFFFFF; border: 1px solid #3E3E3E; font-size: 16px; padding: 10px; }
        """)
        self.text_area.setPlaceholderText("Translation will appear here...")
        layout.addWidget(self.text_area)
        
        # Status Bar
        self.status_bar = QStatusBar()
        self.status_bar.setStyleSheet("background-color: #007ACC; color: white;")
        self.setStatusBar(self.status_bar)
        self.status_bar.showMessage("Ready")

    def _populate_output_devices(self):
        self.output_selector.clear()
        devices = DeviceManager.get_output_devices()
        for device in devices:
            self.output_selector.addItem(device['name'], device['id'])

    def _on_output_device_changed(self, index):
        device_id = self.output_selector.currentData()
        if device_id is not None:
            self.audio_playback.set_device(device_id)

    def _on_volume_changed(self, value):
        self.volume_value_label.setText(f"{value}%")
        self.audio_playback.set_volume(value / 100.0)

    def _toggle_mute(self):
        muted = self.audio_playback.toggle_mute()
        self.mute_btn.setText("🔇" if muted else "🔊")

    def _update_status(self, status_code, message=None):
        status_map = {
            "ready": "⏸️ Ready",
            "capturing": "🎤 Capturing",
            "sending": "📤 Sending",
            "receiving": "📥 Receiving",
            "translating": "✅ Translating",
            "no_audio": "⚠️ No Audio (Check Mic)",
            "error": "❌ Error"
        }
        
        text = status_map.get(status_code, status_code)
        if message:
            text += f" - {message}"
        
        self.status_indicator.setText(text)
        
        colors = {
            "ready": "#AAAAAA",
            "capturing": "#00AAFF",
            "sending": "#FFAA00",
            "receiving": "#00FFAA",
            "translating": "#00FF00",
            "no_audio": "#FFAA00",
            "error": "#FF5555"
        }
        self.status_indicator.setStyleSheet(f"color: {colors.get(status_code, '#FFFFFF')}; font-size: 14px; font-weight: bold; margin: 5px 0;")

    def _on_audio_level_update(self, level):
        self.level_meter.setValue(int(level))
        if level > 5:
            self.last_audio_time = time.time()
            # If we were in 'no_audio' state, revert to capturing/translating
            if "No Audio" in self.status_indicator.text():
                self._update_status("capturing")

    def _check_silence(self):
        if self.last_audio_time and self.is_running:
            silence_duration = time.time() - self.last_audio_time
            if silence_duration > 5:
                self._update_status("no_audio")

    @asyncSlot()
    async def _preview_audio_source(self):
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
        
        try:
            temp_capture = AudioCapture(device_id=device_id, on_level_update=on_level)
            await temp_capture.start()
            
            await asyncio.sleep(2)
            
            temp_capture.stop()
            
            if max_level > 10:
                self.preview_btn.setText("✅ OK")
            else:
                self.preview_btn.setText("❌ Silent")
        except Exception as e:
            self.preview_btn.setText("❌ Error")
            print(f"Preview error: {e}")
        
        await asyncio.sleep(1)
        self.preview_btn.setText("🔊 Preview")
        self.preview_btn.setEnabled(True)
        self.level_meter.setValue(0)

    def open_settings(self):
        dialog = SettingsDialog(self)
        if dialog.exec():
            self.gemini_client = GeminiClient()
            self.status_bar.showMessage("Settings saved. Client reinitialized.")

    @asyncSlot()
    async def toggle_translation(self):
        if self.start_btn.isChecked():
            await self.start_translation()
        else:
            await self.stop_translation()

    async def start_translation(self):
        device_id = self.audio_selector.get_selected_device_id()
        if device_id is None:
            self.status_bar.showMessage("No audio device selected.")
            self.start_btn.setChecked(False)
            return

        self.start_btn.setText("Stop Translation")
        self.start_btn.setStyleSheet("background-color: #FF5555; color: white; padding: 10px 20px; border-radius: 4px; border: none; font-weight: bold; font-size: 14px;")
        self.text_area.clear()
        self.status_bar.showMessage("Connecting...")
        self._update_status("ready", "Connecting...")
        
        try:
            self.audio_capture = AudioCapture(device_id=device_id, on_level_update=self._on_audio_level_update)
            await self.audio_capture.start()

            await self.audio_playback.start()

            if settings.get("output", "auto_save", True):
                self.file_writer.start_session()
            
            await self.gemini_client.connect()
            
            self.process_task = asyncio.create_task(self.process_audio_stream())
            
            self.status_bar.showMessage("Translating...")
            self._update_status("capturing")
            self.is_running = True
            
            self.last_audio_time = time.time()
            self.silence_check_timer.start(1000)
            
        except Exception as e:
            print(f"Start Error: {e}")
            self.status_bar.showMessage(f"Error: {e}")
            self._update_status("error", str(e))
            await self.stop_translation()

    async def stop_translation(self):
        self.is_running = False
        self.status_bar.showMessage("Stopping...")
        self.silence_check_timer.stop()
        
        if self.audio_capture:
            self.audio_capture.stop()
            self.audio_capture = None

        await self.audio_playback.stop()

        self.file_writer.close_session()
            
        if self.gemini_client:
            self.gemini_client.disconnect()
            
        if self.process_task:
            self.process_task.cancel()
            try:
                await self.process_task
            except asyncio.CancelledError:
                pass
            self.process_task = None

        self.start_btn.setText("Start Translation")
        self.start_btn.setChecked(False)
        self.start_btn.setStyleSheet("""
            QPushButton { background-color: #007ACC; color: white; padding: 10px 20px; border-radius: 4px; border: none; font-weight: bold; font-size: 14px; }
            QPushButton:hover { background-color: #0098FF; }
        """)
        self.status_bar.showMessage("Stopped")
        self._update_status("ready")
        self.level_meter.setValue(0)

    async def process_audio_stream(self):
        try:
            text_count = 0
            audio_count = 0

            # Accumulate transcriptions like the reference project
            input_transcription_buffer = []
            output_transcription_buffer = []
            last_display_type = None  # Track what was last displayed

            # Pass actual sample rate from capture device to API
            sample_rate = self.audio_capture.sample_rate or 16000
            async for item in self.gemini_client.stream_audio(self.audio_capture.queue, sample_rate=sample_rate):
                if not isinstance(item, tuple):
                    continue

                item_type, data = item

                # Handle audio
                if item_type == "audio":
                    audio_count += 1
                    if audio_count % 10 == 0:
                        print(f"[UI] Received audio #{audio_count}: {len(data)} bytes")
                    await self.audio_playback.queue_audio(data)
                    continue

                # Handle transcriptions - accumulate without line breaks
                if item_type == "input_transcription":
                    if not data or not data.strip():
                        continue
                    text_count += 1
                    # Don't log every word - too verbose

                    # If we were showing output, start new line for input
                    if last_display_type == "output":
                        self.text_area.moveCursor(self.text_area.textCursor().MoveOperation.End)
                        self.text_area.insertPlainText("\n[EN] ")
                        input_transcription_buffer = []
                    elif last_display_type is None or not input_transcription_buffer:
                        # First input or new session
                        self.text_area.moveCursor(self.text_area.textCursor().MoveOperation.End)
                        self.text_area.insertPlainText("[EN] ")

                    # Append text inline (no line break)
                    self.text_area.moveCursor(self.text_area.textCursor().MoveOperation.End)
                    self.text_area.insertPlainText(data)
                    input_transcription_buffer.append(data)
                    last_display_type = "input"

                    # Save to file
                    self.file_writer.write_line(f"[EN] {data}", newline=False)

                elif item_type == "output_transcription":
                    if not data or not data.strip():
                        continue
                    text_count += 1
                    # Don't log every word - too verbose
                    self._update_status("translating")

                    # If we were showing input, start new line for output
                    if last_display_type == "input":
                        self.text_area.moveCursor(self.text_area.textCursor().MoveOperation.End)
                        self.text_area.insertPlainText("\n[KO] ")
                        output_transcription_buffer = []
                    elif last_display_type is None or not output_transcription_buffer:
                        # First output or new session
                        self.text_area.moveCursor(self.text_area.textCursor().MoveOperation.End)
                        self.text_area.insertPlainText("[KO] ")

                    # Append text inline (no line break)
                    self.text_area.moveCursor(self.text_area.textCursor().MoveOperation.End)
                    self.text_area.insertPlainText(data)
                    output_transcription_buffer.append(data)
                    last_display_type = "output"

                    # Save to file
                    self.file_writer.write_line(f"[KO] {data}", newline=False)

                elif item_type == "text":
                    if not data or not data.strip():
                        continue
                    text_count += 1
                    print(f"[UI] Received text #{text_count}: '{data}'")
                    self._update_status("translating")

                    # Text gets its own line
                    self.text_area.moveCursor(self.text_area.textCursor().MoveOperation.End)
                    self.text_area.insertPlainText(f"\n{data}")
                    self.file_writer.write_line(data)

                self.text_area.moveCursor(self.text_area.textCursor().MoveOperation.End)

            print(f"[UI] Stream ended. Total text: {text_count}, audio: {audio_count}")

        except asyncio.CancelledError:
            print(f"[UI] Stream cancelled")
            raise
        except Exception as e:
            print(f"[UI] Stream processing error: {e}")
            import traceback
            traceback.print_exc()
            self.status_bar.showMessage(f"Stream Error: {e}")
            self._update_status("error", str(e))
