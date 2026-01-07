import yaml
import os

class SettingsManager:
    _instance = None
    _config = None

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super(SettingsManager, cls).__new__(cls)
            cls._instance.load_config()
        return cls._instance

    def load_config(self):
        """Loads configuration from config.yaml"""
        config_path = "config.yaml"
        if os.path.exists(config_path):
            with open(config_path, 'r', encoding='utf-8') as f:
                self._config = yaml.safe_load(f)
        else:
            # Fallback to defaults if file missing
            self._config = {
                "audio": {"sample_rate": 16000, "channels": 1, "buffer_size": 1024},
                "translation": {
                    "model": "gemini-2.5-flash-preview-native-audio-dialog",
                    "language_from": "en",
                    "language_to": "ko",
                    "streaming": True
                },
                "output": {"auto_save": True}
            }
    
    def get(self, section, key, default=None):
        """Retrieves a configuration value safely."""
        return self._config.get(section, {}).get(key, default)

    def set(self, section, key, value):
        """Sets a configuration value and saves to file."""
        if section not in self._config:
            self._config[section] = {}
        self._config[section][key] = value
        self.save_config()

    def save_config(self):
        """Saves current configuration to config.yaml"""
        with open("config.yaml", 'w', encoding='utf-8') as f:
            yaml.dump(self._config, f, default_flow_style=False)

# Global instance
settings = SettingsManager()
