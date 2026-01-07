from PyQt6.QtWidgets import (QDialog, QVBoxLayout, QHBoxLayout, QLabel, 
                             QLineEdit, QComboBox, QPushButton, QMessageBox, QGroupBox, QFormLayout)
from PyQt6.QtCore import Qt
from src.config.settings_manager import settings
from src.config.secure_storage import SecureStorage
from src.translator.model_fetcher import ModelFetcher

class SettingsDialog(QDialog):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Settings")
        self.setMinimumWidth(400)
        self.setStyleSheet("""
            QDialog { background-color: #1E1E1E; color: #FFFFFF; }
            QLabel { color: #FFFFFF; }
            QLineEdit { background-color: #2D2D2D; color: #FFFFFF; border: 1px solid #3E3E3E; padding: 5px; }
            QComboBox { background-color: #2D2D2D; color: #FFFFFF; border: 1px solid #3E3E3E; padding: 5px; }
            QGroupBox { color: #FFFFFF; border: 1px solid #3E3E3E; margin-top: 10px; }
            QGroupBox::title { subcontrol-origin: margin; subcontrol-position: top center; padding: 0 3px; }
            QPushButton { background-color: #007ACC; color: #FFFFFF; border: none; padding: 8px 15px; border-radius: 4px; }
            QPushButton:hover { background-color: #0098FF; }
            QPushButton#cancelButton { background-color: #3E3E3E; }
            QPushButton#cancelButton:hover { background-color: #4E4E4E; }
        """)
        
        self.layout = QVBoxLayout(self)
        self.init_ui()
        self.load_settings()

    def init_ui(self):
        # API Configuration Group
        api_group = QGroupBox("API Configuration")
        api_layout = QFormLayout()
        
        # Provider (Fixed)
        self.provider_label = QLabel("Google Gemini")
        api_layout.addRow("API Provider:", self.provider_label)
        
        # API Key
        self.api_key_input = QLineEdit()
        self.api_key_input.setEchoMode(QLineEdit.EchoMode.Password)
        self.api_key_input.setPlaceholderText("Paste your Gemini API Key here")
        api_layout.addRow("API Key:", self.api_key_input)
        
        # API Key Help Text
        help_label = QLabel("Key is stored locally securely.")
        help_label.setStyleSheet("color: #AAAAAA; font-size: 11px;")
        api_layout.addRow("", help_label)
        
        # Model Selection
        model_layout = QHBoxLayout()
        self.model_combo = QComboBox()
        self.refresh_btn = QPushButton("↻")
        self.refresh_btn.setFixedWidth(30)
        self.refresh_btn.setToolTip("Refresh Models")
        self.refresh_btn.clicked.connect(self.refresh_models)
        
        model_layout.addWidget(self.model_combo)
        model_layout.addWidget(self.refresh_btn)
        api_layout.addRow("Model:", model_layout)
        
        api_group.setLayout(api_layout)
        self.layout.addWidget(api_group)
        
        # Buttons
        btn_layout = QHBoxLayout()
        btn_layout.addStretch()
        
        self.cancel_btn = QPushButton("Cancel")
        self.cancel_btn.setObjectName("cancelButton")
        self.cancel_btn.clicked.connect(self.reject)
        
        self.save_btn = QPushButton("Save")
        self.save_btn.clicked.connect(self.save_settings)
        
        btn_layout.addWidget(self.cancel_btn)
        btn_layout.addWidget(self.save_btn)
        
        self.layout.addStretch()
        self.layout.addLayout(btn_layout)

    def load_settings(self):
        # Load API Key
        api_key = SecureStorage.get_api_key()
        if api_key:
            self.api_key_input.setText(api_key)
            
        # Load Models
        self.refresh_models()
        
        # Select current model
        current_model = settings.get("translation", "model")
        index = self.model_combo.findData(current_model)
        if index >= 0:
            self.model_combo.setCurrentIndex(index)

    def refresh_models(self):
        self.model_combo.clear()
        # Fetch models (this might block UI slightly, ideally async but keep simple for now)
        models = ModelFetcher.get_models(force_refresh=True)
        for model in models:
            self.model_combo.addItem(model['displayName'], model['name'])

    def save_settings(self):
        api_key = self.api_key_input.text().strip()
        if not api_key:
            QMessageBox.warning(self, "Validation Error", "API Key is required.")
            return

        # Save API Key
        SecureStorage.save_api_key(api_key)
        
        # Save Model
        selected_model = self.model_combo.currentData()
        if selected_model:
            settings.set("translation", "model", selected_model)
            
        self.accept()
