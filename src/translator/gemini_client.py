import os
import asyncio
import google.generativeai as genai
from src.config.secure_storage import SecureStorage
from src.config.settings_manager import settings

class GeminiClient:
    """
    Client for interacting with Google Gemini API for real-time translation.
    """
    
    def __init__(self):
        self.api_key = SecureStorage.get_api_key()
        self.model_name = settings.get("translation", "model")
        self.chat_session = None
        self.is_connected = False
        
        if self.api_key:
            genai.configure(api_key=self.api_key)

    async def connect(self):
        """
        Initializes the chat session with the Gemini model.
        """
        if not self.api_key:
            # Try reloading in case it was set after init
            self.api_key = SecureStorage.get_api_key()
            if self.api_key:
                genai.configure(api_key=self.api_key)
            else:
                raise ValueError("API Key is missing")
            
        try:
            # Fetch model name from settings again to be sure
            self.model_name = settings.get("translation", "model")
            model = genai.GenerativeModel(self.model_name)
            
            # System prompt setup
            system_prompt = (
                "You are a real-time interpreter. Translate English speech to Korean immediately as you hear it. "
                "Provide translations in a natural, conversational Korean style. "
                "If you hear technical terms or proper nouns, transliterate them appropriately."
            )
            
            # Start chat session
            self.chat_session = model.start_chat(history=[
                {"role": "user", "parts": [system_prompt]},
                {"role": "model", "parts": ["Understood. I am ready to translate English speech to Korean in real-time."]}
            ])
            self.is_connected = True
            print(f"Connected to Gemini model: {self.model_name}")
            
        except Exception as e:
            print(f"Failed to connect to Gemini: {e}")
            self.is_connected = False
            raise

    async def send_audio_chunk(self, audio_data):
        """
        Sends an audio chunk to the model and yields the translated text.
        
        Args:
            audio_data (bytes): Raw audio data (ideally with container format like WAV if needed, 
                               or relying on model's ability to ingest raw PCM if configured).
            
        Yields:
            str: Translated text chunks.
        """
        if not self.is_connected or not self.chat_session:
            return

        try:
            # Sending audio blob. The mime_type depends on what we send.
            # Using audio/wav is safer if we include headers, or audio/pcm if supported.
            # For now, we assume the caller handles the formatting or we send raw PCM assuming 16k mono.
            
            response = await self.chat_session.send_message_async(
                {"mime_type": "audio/wav", "data": audio_data}, 
                stream=True
            )
            
            async for chunk in response:
                if chunk.text:
                    yield chunk.text
                    
        except Exception as e:
            print(f"Error sending audio: {e}")
            # Simple error handling: disconnect to force reconnect logic elsewhere
            self.is_connected = False

    def disconnect(self):
        self.chat_session = None
        self.is_connected = False
