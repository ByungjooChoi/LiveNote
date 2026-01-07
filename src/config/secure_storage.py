import os
from dotenv import load_dotenv, set_key

class SecureStorage:
    """
    Manages secure storage for sensitive data like API keys.
    Uses .env file for storage.
    """
    
    @staticmethod
    def get_api_key():
        """Retrieves the Gemini API key from environment variables."""
        load_dotenv()
        return os.getenv("GEMINI_API_KEY")

    @staticmethod
    def save_api_key(api_key):
        """Saves the Gemini API key to the .env file."""
        # Update current environment
        os.environ["GEMINI_API_KEY"] = api_key
        # Save to .env file, create if not exists
        env_path = ".env"
        if not os.path.exists(env_path):
            with open(env_path, 'w') as f:
                f.write("")
        set_key(env_path, "GEMINI_API_KEY", api_key)
