import asyncio
from PyQt6.QtWidgets import (QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, 
                             QTextEdit, QPushButton, QLabel, QStatusBar)
from PyQt6.QtCore import Qt
from qasync import asyncSlot

from src.ui.settings_dialog import SettingsDialog
from src.ui.audio_selector import AudioSelector
from src.audio.capture import AudioCapture
from src.translator.gemini_client import GeminiClient
from src.config.secure_storage import SecureStorage
from src.utils.file_writer import FileWriter
from src.config.settings_manager import settings

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
        
        self.init_ui()
        
        # Check API Key on startup
        if not SecureStorage.get_api_key():
            self.open_settings()

    def init_ui(self):
        central_widget = QWidget()
        self.setCentralWidget(central_widget)
        layout = QVBoxLayout(central_widget)
        
        # Top Bar
        top_layout = QHBoxLayout()
        
        self.audio_selector = AudioSelector()
        top_layout.addWidget(self.audio_selector, 1)
        
        self.start_btn = QPushButton("Start Translation")
        self.start_btn.setStyleSheet("""
            QPushButton { background-color: #007ACC; color: white; padding: 8px 15px; border-radius: 4px; border: none; font-weight: bold; }
            QPushButton:hover { background-color: #0098FF; }
            QPushButton:checked { background-color: #FF5555; }
        """)
        self.start_btn.setCheckable(True)
        self.start_btn.clicked.connect(self.toggle_translation)
        top_layout.addWidget(self.start_btn)
        
        self.settings_btn = QPushButton("⚙️")
        self.settings_btn.setFixedWidth(40)
        self.settings_btn.setStyleSheet("background-color: #3E3E3E; border-radius: 4px; border: none;")
        self.settings_btn.clicked.connect(self.open_settings)
        top_layout.addWidget(self.settings_btn)
        
        layout.addLayout(top_layout)
        
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

    def open_settings(self):
        dialog = SettingsDialog(self)
        if dialog.exec():
            self.status_bar.showMessage("Settings saved.")

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
            # gemini_client.stream_audio takes the queue and yields text
            async for text in self.gemini_client.stream_audio(self.audio_capture.queue):
                # Skip empty text
                if not text or not text.strip():
                    continue
                    
                # Ensure UI update happens on main thread (qasync handles this generally, but appending is safe)
                self.text_area.moveCursor(self.text_area.textCursor().MoveOperation.End)
                self.text_area.insertPlainText(text + " ") # Add space or newline
                self.text_area.moveCursor(self.text_area.textCursor().MoveOperation.End)
                
                # Write to file
                self.file_writer.write_line(text)
                
        except Exception as e:
            print(f"Stream processing error: {e}")
            self.status_bar.showMessage(f"Stream Error: {e}")
