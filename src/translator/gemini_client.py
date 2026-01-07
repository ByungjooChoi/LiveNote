import asyncio
import os
import traceback
import numpy as np
from google import genai
from src.config.secure_storage import SecureStorage
from src.config.settings_manager import settings

class GeminiClient:
    """
    Client for interacting with Google Gemini Live API (WebSocket).
    """
    
    def __init__(self):
        self.api_key = SecureStorage.get_api_key()
        self.model_name = settings.get("translation", "model")
        
        # Ensure we use a model compatible with Live API
        # If the config model seems to be a REST model or older, fallback to a known Live model
        # or rely on what's in config if user updated it correctly.
        LIVE_API_PATTERNS = ["gemini-2.0", "gemini-2.5", "gemini-exp"]
        
        if not any(pattern in self.model_name for pattern in LIVE_API_PATTERNS):
             print(f"Warning: Configured model '{self.model_name}' might not support Live API. Switching to default.")
             self.model_name = "gemini-2.5-flash-preview-native-audio-dialog"
             
        self.client = None
        self.session = None
        self.is_connected = False
        
        if self.api_key:
            # Initialize with v1alpha for Live API access
            self.client = genai.Client(api_key=self.api_key, http_options={"api_version": "v1alpha"})

    async def connect(self):
        """
        Prepares the client. Actual connection happens in the stream context.
        """
        if not self.api_key:
            self.api_key = SecureStorage.get_api_key()
            if self.api_key:
                 self.client = genai.Client(api_key=self.api_key, http_options={"api_version": "v1alpha"})
            else:
                raise ValueError("API Key is missing")
        
        self.is_connected = True
        print(f"Gemini Client initialized for model: {self.model_name}")

    async def stream_audio(self, audio_queue):
        """
        Connects to Live API and streams audio from the queue.
        
        Args:
            audio_queue (asyncio.Queue): Queue containing audio chunks.
            
        Yields:
            str: Translated text chunks.
        """
        if not self.client:
            print("Client not initialized")
            return

        config = {
            "generation_config": {
                "response_modalities": ["TEXT"]  # We only want text translation back
            },
            "system_instruction": {
                "parts": [
                    {"text": "You are a real-time interpreter. Translate English speech to Korean immediately as you hear it. Provide translations in a natural, conversational Korean style."}
                ]
            }
        }

        try:
            print(f"Connecting to Live API with model: {self.model_name}...")
            async with self.client.aio.live.connect(model=self.model_name, config=config) as session:
                self.session = session
                print("Connected to Gemini Live API")
                
                # Start a task to send audio
                send_task = asyncio.create_task(self._send_audio_loop(session, audio_queue))
                
                try:
                    while True:
                         async for response in session.receive():
                            if response.server_content and response.server_content.model_turn:
                                for part in response.server_content.model_turn.parts:
                                    if part.text:
                                        yield part.text
                except asyncio.CancelledError:
                    print("Receive loop cancelled")
                except Exception as e:
                    print(f"Error in receive loop: {e}")
                finally:
                    send_task.cancel()
                    try:
                        await send_task
                    except asyncio.CancelledError:
                        pass

        except Exception as e:
            print(f"Live API Connection Error: {e}")
            traceback.print_exc()
            self.is_connected = False

    async def _send_audio_loop(self, session, audio_queue):
        """
        Continuously takes audio from queue and sends to session.
        """
        try:
            while True:
                item = await audio_queue.get()
                
                # Handle tuple (data, rms) from capture.py
                if isinstance(item, tuple):
                    audio_data = item[0]
                else:
                    audio_data = item

                # Convert numpy array to bytes
                if hasattr(audio_data, 'tobytes'):
                    audio_data = audio_data.tobytes()
                
                # Send to Live API
                # Using audio/pcm requires raw PCM data (16-bit little-endian, usually)
                # sounddevice returns float32 by default unless configured otherwise.
                # We need to ensure it's sent as expected.
                # The capture.py default is float32. We should convert to int16 PCM for better compatibility 
                # or ensure API supports float32 PCM. Usually int16 is safer.
                
                # Simple float32 -> int16 conversion
                # if dtype is float32, range is -1.0 to 1.0
                # int16 range is -32768 to 32767
                if isinstance(audio_data, bytes) and len(audio_data) > 0:
                     # Check if it was already bytes (unlikely if coming from numpy without conversion)
                     pass
                elif hasattr(item, 'dtype') or isinstance(item, tuple):
                     # Re-access original numpy array if possible to convert
                     arr = item[0] if isinstance(item, tuple) else item
                     if hasattr(arr, 'dtype') and arr.dtype == np.float32:
                         audio_data = (arr * 32767).astype(np.int16).tobytes()

                await session.send({
                    "realtime_input": {
                        "media_chunks": [{
                            "mime_type": "audio/pcm",
                            "data": audio_data
                        }]
                    }
                })
        except asyncio.CancelledError:
            pass
        except Exception as e:
            print(f"Error sending audio loop: {e}")

    def disconnect(self):
        self.is_connected = False
