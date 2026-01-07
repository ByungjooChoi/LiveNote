import asyncio
import os
import traceback
import time
import numpy as np
from google import genai
from google.genai import types
from src.config.secure_storage import SecureStorage
from src.config.settings_manager import settings

class SessionExpiredError(Exception):
    """Raised when session needs to be refreshed."""
    pass

class GeminiClient:
    """
    Client for interacting with Google Gemini Live API (WebSocket).
    """
    
    SESSION_TIMEOUT = 14 * 60  # 14 minutes
    
    def __init__(self):
        self.api_key = SecureStorage.get_api_key()
        self.model_name = settings.get("translation", "model")
        
        # Ensure we use a model compatible with Live API
        # If the config model seems to be a REST model or older, fallback to a known Live model
        # or rely on what's in config if user updated it correctly.
        LIVE_API_PATTERNS = ["gemini-2.0", "gemini-2.5", "gemini-exp"]
        
        if not any(pattern in self.model_name for pattern in LIVE_API_PATTERNS):
             print(f"Warning: Configured model '{self.model_name}' might not support Live API. Switching to default.")
             self.model_name = "gemini-2.0-flash-exp"
             
        self.client = None
        self.session = None
        self.is_connected = False
        self.session_start_time = None
        self._reconnecting = False
        
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
        Automatically reconnects before session timeout.
        """
        while self.is_connected:
            try:
                self._reconnecting = False
                async for item in self._stream_audio_session(audio_queue):
                    yield item
            except SessionExpiredError:
                print("Session expired, reconnecting...")
                # Add a small delay to avoid rapid looping if reconnection fails immediately
                await asyncio.sleep(1)
                continue
            except Exception as e:
                # If we manually disconnected, stop loop
                if not self.is_connected:
                    break
                
                print(f"Stream connection ended: {e}")
                # For other errors, we might want to stop or retry.
                # For now, let's stop to avoid infinite error loops unless it's a known transient error.
                break

    async def _stream_audio_session(self, audio_queue):
        """Single session stream with timeout monitoring."""
        if not self.client:
            print("Client not initialized")
            return

        # Check if using Native Audio model
        is_native_audio = "native-audio" in self.model_name

        if is_native_audio:
            # Native Audio model requires AUDIO modality, but returns both TEXT and AUDIO.
            config = types.LiveConnectConfig(
                response_modalities=["AUDIO"],
                speech_config=types.SpeechConfig(
                    voice_config=types.VoiceConfig(
                        prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Aoede")
                    )
                ),
                system_instruction=types.Content(
                    parts=[types.Part(text="You are a real-time interpreter. Listen to English speech and respond with Korean translation in both text and speech. Speak naturally in Korean.")]
                )
            )
        else:
            config = types.LiveConnectConfig(
                response_modalities=["TEXT"],
                system_instruction=types.Content(
                    parts=[types.Part(text="You are a real-time interpreter. Translate English speech to Korean immediately as you hear it. Provide translations in a natural, conversational Korean style.")]
                )
            )

        try:
            print(f"Connecting to Live API with model: {self.model_name}...")
            async with self.client.aio.live.connect(model=self.model_name, config=config) as session:
                self.session = session
                self.session_start_time = time.time()
                print("Connected to Gemini Live API")
                
                # Start tasks
                # Pass session start time to monitor to avoid race conditions
                send_task = asyncio.create_task(self._send_audio_loop(session, audio_queue))
                timeout_task = asyncio.create_task(self._session_timeout_monitor(audio_queue))
                
                try:
                    while True:
                         async for response in session.receive():
                            if response.server_content and response.server_content.model_turn:
                                for part in response.server_content.model_turn.parts:
                                    if part.text:
                                        yield ("text", part.text)
                                    elif part.inline_data and part.inline_data.mime_type.startswith("audio/"):
                                        yield ("audio", part.inline_data.data)
                except asyncio.CancelledError:
                    print("Receive loop cancelled")
                finally:
                    send_task.cancel()
                    timeout_task.cancel()
                    try:
                        await send_task
                        await timeout_task
                    except asyncio.CancelledError:
                        pass
                    except SessionExpiredError:
                        # Propagate session expired error to trigger reconnection
                        raise

        except SessionExpiredError:
            raise
        except Exception as e:
            if not self._reconnecting and self.is_connected:
                print(f"Live API Connection Error: {e}")
                traceback.print_exc()
            raise

    async def _send_audio_loop(self, session, audio_queue):
        """
        Continuously takes audio from queue and sends to session.
        """
        try:
            while True:
                item = await audio_queue.get()
                
                # Check for session timeout signal from monitor
                if item is SessionExpiredError or self._reconnecting:
                    raise SessionExpiredError("Session timeout")

                # Handle tuple (data, rms) from capture.py
                if isinstance(item, tuple):
                    audio_data = item[0]
                else:
                    audio_data = item

                # Convert numpy array to bytes
                if hasattr(audio_data, 'tobytes'):
                    audio_data = audio_data.tobytes()
                
                # Send to Live API
                await session.send(
                    input=types.LiveClientRealtimeInput(
                        media_chunks=[
                            types.Blob(data=audio_data, mime_type="audio/pcm")
                        ]
                    )
                )
        except asyncio.CancelledError:
            pass
        except SessionExpiredError:
            raise
        except Exception as e:
            if not self._reconnecting:
                print(f"Error sending audio loop: {e}")

    async def _session_timeout_monitor(self, audio_queue):
        """Monitor session timeout and trigger reconnection."""
        try:
            while True:
                await asyncio.sleep(10)  # Check every 10 seconds
                
                if self.session_start_time:
                    elapsed = time.time() - self.session_start_time
                    remaining = self.SESSION_TIMEOUT - elapsed
                    
                    if 0 < remaining < 60:
                        # Could use a callback to update UI, but for now just print
                        pass 
                    
                    if elapsed >= self.SESSION_TIMEOUT:
                        print("Session timeout reached, triggering reconnection...")
                        self._reconnecting = True
                        # Signal send loop to raise exception
                        await audio_queue.put(SessionExpiredError)
                        # Also raise here to be safe (though this task just dies)
                        raise SessionExpiredError("Session timeout")
                        
        except asyncio.CancelledError:
            pass

    def disconnect(self):
        self.is_connected = False
