import asyncio
from PyQt6.QtWidgets import (QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, 
                             QTextEdit, QPushButton, QLabel, QStatusBar, QSlider, QComboBox)
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
        
        self.init_ui()
        
        # Check API Key on startup
        if not SecureStorage.get_api_key():
            self.open_settings()

    def init_ui(self):
        central_widget = QWidget()
        self.setCentralWidget(central_widget)
        layout = QVBoxLayout(central_widget)
        
        # 1. Input Source
        self.audio_selector = AudioSelector()
        layout.addWidget(self.audio_selector)

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
        
        # 3. Control Buttons
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
        
        # Populate output devices after UI setup
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

    def open_settings(self):
        dialog = SettingsDialog(self)
        if dialog.exec():
            # Reinitialize GeminiClient with new settings
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
        self.start_btn.setStyleSheet("background-color: #FF5555; color: white; padding: 8px 15px; border-radius: 4px; border: none; font-weight: bold;")
        self.text_area.clear()
        self.status_bar.showMessage("Connecting...")
        
        try:
            # Initialize Audio Capture
            # Note: capture.py creates its own queue
            self.audio_capture = AudioCapture(device_id=device_id)
            await self.audio_capture.start()

            # Start Audio Playback
            await self.audio_playback.start()

            # Start File Session
            if settings.get("output", "auto_save", True):
                self.file_writer.start_session()
            
            # Connect Gemini
            await self.gemini_client.connect()
            
            # Start Processing Loop (Connects capture queue to gemini stream)
            self.process_task = asyncio.create_task(self.process_audio_stream())
            
            self.status_bar.showMessage("Translating...")
            self.is_running = True
            
        except Exception as e:
            print(f"Start Error: {e}")
            self.status_bar.showMessage(f"Error: {e}")
            await self.stop_translation()

    async def stop_translation(self):
        self.is_running = False
        self.status_bar.showMessage("Stopping...")
        
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
            QPushButton { background-color: #007ACC; color: white; padding: 8px 15px; border-radius: 4px; border: none; font-weight: bold; }
            QPushButton:hover { background-color: #0098FF; }
        """)
        self.status_bar.showMessage("Stopped")

    async def process_audio_stream(self):
        try:
            # gemini_client.stream_audio takes the queue and yields (type, data) tuple or text
            async for item in self.gemini_client.stream_audio(self.audio_capture.queue):
                text_to_display = ""
                
                if isinstance(item, tuple):
                    item_type, data = item
                    if item_type == "text":
                        text_to_display = data
                    elif item_type == "audio":
                        await self.audio_playback.queue_audio(data)
                        continue
                else:
                    # Backward compatibility for text-only yield
                    text_to_display = item

                # Skip empty text
                if not text_to_display or not text_to_display.strip():
                    continue
                    
                # Ensure UI update happens on main thread (qasync handles this generally, but appending is safe)
                self.text_area.moveCursor(self.text_area.textCursor().MoveOperation.End)
                self.text_area.insertPlainText(text_to_display + " ") # Add space or newline
                self.text_area.moveCursor(self.text_area.textCursor().MoveOperation.End)
                
                # Write to file
                self.file_writer.write_line(text_to_display)
                
        except Exception as e:
            print(f"Stream processing error: {e}")
            self.status_bar.showMessage(f"Stream Error: {e}")
