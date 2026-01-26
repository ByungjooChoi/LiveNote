from PyQt6.QtWidgets import QWidget, QHBoxLayout, QComboBox, QPushButton, QLabel
from src.audio.device_manager import DeviceManager

class AudioSelector(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.layout = QHBoxLayout(self)
        self.layout.setContentsMargins(0, 0, 0, 0)
        
        self.label = QLabel("Audio Source:")
        self.label.setStyleSheet("color: #FFFFFF;")
        
        self.combo = QComboBox()
        self.combo.setStyleSheet("background-color: #2D2D2D; color: #FFFFFF; border: 1px solid #3E3E3E; padding: 5px;")
        
        self.refresh_btn = QPushButton("↻")
        self.refresh_btn.setFixedWidth(30)
        self.refresh_btn.setStyleSheet("""
            QPushButton { background-color: #3E3E3E; color: #FFFFFF; border: none; border-radius: 4px; }
            QPushButton:hover { background-color: #4E4E4E; }
        """)
        self.refresh_btn.clicked.connect(self.refresh_devices)
        
        self.layout.addWidget(self.label)
        self.layout.addWidget(self.combo, 1)
        self.layout.addWidget(self.refresh_btn)
        
        self.refresh_devices()

    def refresh_devices(self):
        self.combo.clear()
        devices = DeviceManager.get_input_devices()
        blackhole_index = -1

        for i, device in enumerate(devices):
            # Display name like: "Microphone (Realtek Audio)"
            name = device['name']
            device_id = device['id']
            self.combo.addItem(name, device_id)

            # Track BlackHole device index for default selection
            if 'blackhole' in name.lower():
                blackhole_index = i

        # Default to BlackHole if found
        if blackhole_index >= 0:
            self.combo.setCurrentIndex(blackhole_index)
            
    def get_selected_device_id(self):
        return self.combo.currentData()
