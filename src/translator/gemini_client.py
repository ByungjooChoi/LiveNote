import asyncio
import traceback
import time
import numpy as np
from google import genai
from src.config.secure_storage import SecureStorage
from src.config.settings_manager import settings

class SessionExpiredError(Exception):
    """Raised when session needs to be refreshed."""
    pass

# Constants - same as official example
SEND_SAMPLE_RATE = 16000
RECEIVE_SAMPLE_RATE = 24000

# Model and config - based on official Gemini cookbook example
MODEL = "gemini-2.5-flash-native-audio-preview-12-2025"
SYSTEM_INSTRUCTION = """You are a real-time SIMULTANEOUS interpreter translating English to Korean.

CRITICAL RULES:
1. Translate AS YOU HEAR - do NOT wait for complete sentences
2. Start translating after hearing just a few words
3. Use short, natural Korean phrases
4. If you miss something, skip it and continue with current speech
5. Never explain or comment - ONLY output Korean translation
6. Respond as quickly as possible, even with partial translations
"""

CONFIG = {
    "system_instruction": SYSTEM_INSTRUCTION,
    "response_modalities": ["AUDIO"],
    "speech_config": {
        "voice_config": {
            "prebuilt_voice_config": {"voice_name": "Kore"}
        }
    },
    # Realtime input config for continuous streaming / simultaneous interpretation
    "realtime_input_config": {
        "automatic_activity_detection": {
            "disabled": False,
            # Lower threshold = more sensitive = responds faster
            "start_of_speech_sensitivity": "START_OF_SPEECH_SENSITIVITY_HIGH",
            "end_of_speech_sensitivity": "END_OF_SPEECH_SENSITIVITY_HIGH",
        }
    },
}


class GeminiClient:
    """
    Client for interacting with Google Gemini Live API (WebSocket).
    Based on official Google Gemini cookbook example.
    """

    SESSION_TIMEOUT = 14 * 60  # 14 minutes

    def __init__(self):
        self.api_key = SecureStorage.get_api_key()
        self.model_name = settings.get("translation", "model")

        # Use native audio model
        if "native-audio" not in self.model_name:
            self.model_name = MODEL

        self.client = None
        self.session = None
        self.is_connected = False
        self.session_start_time = None
        self._reconnecting = False

        if self.api_key:
            # Initialize with v1alpha for Live API access (same as official example)
            self.client = genai.Client(api_key=self.api_key, http_options={"api_version": "v1alpha"})

    async def connect(self):
        """Prepares the client."""
        if not self.api_key:
            self.api_key = SecureStorage.get_api_key()
            if self.api_key:
                self.client = genai.Client(api_key=self.api_key, http_options={"api_version": "v1alpha"})
            else:
                raise ValueError("API Key is missing")

        self.is_connected = True
        print(f"Gemini Client initialized for model: {self.model_name}")

    async def stream_audio(self, audio_queue, sample_rate=16000):
        """
        Connects to Live API and streams audio from the queue.
        """
        while self.is_connected:
            try:
                self._reconnecting = False
                async for item in self._stream_audio_session(audio_queue):
                    yield item
            except SessionExpiredError:
                print("Session expired, reconnecting...")
                await asyncio.sleep(1)
                continue
            except Exception as e:
                if not self.is_connected:
                    break
                print(f"Stream connection ended: {e}")
                break

    async def _stream_audio_session(self, audio_queue):
        """Single session stream - based on official example."""
        if not self.client:
            print("Client not initialized")
            return

        try:
            print(f"Connecting to Live API with model: {self.model_name}...")
            async with self.client.aio.live.connect(model=self.model_name, config=CONFIG) as session:
                self.session = session
                self.session_start_time = time.time()
                print("Connected to Gemini Live API")

                # Create queues for internal communication
                out_queue = asyncio.Queue(maxsize=5)

                # Start tasks - same pattern as official example
                send_task = asyncio.create_task(self._send_realtime(session, out_queue))
                listen_task = asyncio.create_task(self._listen_audio(audio_queue, out_queue))

                try:
                    # Receive loop - based on official example
                    print("Starting receive loop...")
                    response_count = 0
                    while True:
                        turn = session.receive()
                        print(f"Waiting for responses...")
                        async for response in turn:
                            response_count += 1
                            print(f"Response #{response_count}: {type(response)}")

                            # Debug: print raw response
                            print(f"  Raw: data={response.data is not None}, text={response.text is not None}")

                            # Handle audio data - using .data attribute like official example
                            if data := response.data:
                                print(f"  [AUDIO] {len(data)} bytes")
                                yield ("audio", data)
                                continue

                            # Handle text
                            if text := response.text:
                                print(f"  [TEXT] {text}")
                                yield ("text", text)

                        print(f"Turn complete after {response_count} responses")

                except asyncio.CancelledError:
                    print(f"Receive loop cancelled after {response_count} responses")
                finally:
                    send_task.cancel()
                    listen_task.cancel()
                    try:
                        await send_task
                        await listen_task
                    except asyncio.CancelledError:
                        pass

        except SessionExpiredError:
            raise
        except Exception as e:
            if not self._reconnecting and self.is_connected:
                print(f"Live API Connection Error: {e}")
                traceback.print_exc()
            raise

    async def _listen_audio(self, audio_queue, out_queue):
        """Read from capture queue and put into send queue."""
        try:
            while True:
                try:
                    item = await asyncio.wait_for(audio_queue.get(), timeout=0.1)
                except asyncio.TimeoutError:
                    continue

                # Handle tuple (data, rms) from capture.py
                if isinstance(item, tuple):
                    audio_data = item[0]
                else:
                    audio_data = item

                # Convert numpy float32 to int16 bytes (like official example uses pyaudio int16)
                if hasattr(audio_data, 'tobytes'):
                    if hasattr(audio_data, 'dtype') and audio_data.dtype == np.float32:
                        # Clamp and scale - same as livenote-web's float32ToB64PCM
                        audio_data = np.clip(audio_data, -1.0, 1.0)
                        audio_data = (audio_data * 32767).astype(np.int16)
                    audio_data = audio_data.tobytes()

                # Put in send queue - format from official example
                # Official example uses: {"data": data, "mime_type": "audio/pcm"}
                await out_queue.put({"data": audio_data, "mime_type": "audio/pcm"})

        except asyncio.CancelledError:
            pass

    async def _send_realtime(self, session, out_queue):
        """Send audio to API - same as official example."""
        send_count = 0
        try:
            while True:
                msg = await out_queue.get()
                await session.send_realtime_input(audio=msg)
                send_count += 1
                if send_count % 50 == 0:
                    print(f"Sent {send_count} audio chunks to API")
        except asyncio.CancelledError:
            print(f"Send loop cancelled. Total sent: {send_count}")

    def disconnect(self):
        self.is_connected = False
