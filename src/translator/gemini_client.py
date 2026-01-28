import asyncio
import traceback
import time
import os
import numpy as np
from google import genai
from google.genai import types
from google.genai.types import (
    LiveConnectConfig,
    SpeechConfig,
    VoiceConfig,
    PrebuiltVoiceConfig,
    AudioTranscriptionConfig,
    ProactivityConfig,
    HttpOptions,
    RealtimeInputConfig,
    AutomaticActivityDetection,
    StartSensitivity,
    EndSensitivity,
)
from src.config.secure_storage import SecureStorage
from src.config.settings_manager import settings
from src.audio.buffer_manager import BufferedAudioManager


class SessionExpiredError(Exception):
    """Raised when session needs to be refreshed."""
    pass


# Constants
SEND_SAMPLE_RATE = 16000
RECEIVE_SAMPLE_RATE = 24000

# =============================================================================
# Model Definitions (All use Vertex AI now)
# =============================================================================

# Native Audio Model - for real-time translation with proactive responses
# December 2025 version (same as previously working model)
MODEL_NATIVE_AUDIO = "gemini-2.5-flash-native-audio-preview-12-2025"

# S2ST Model - requires Google approval (Private Preview)
MODEL_S2ST = "gemini-2.5-flash-s2st-exp-11-2025"

# =============================================================================
# Model Configurations
# =============================================================================

def get_native_audio_config(source_language="en", target_language="ko", voice_name="Kore"):
    """
    Config for Native Audio model with proactive audio for real-time translation.
    Based on jerryscy/Live-translation-with-Gemini-Live-API-Native-Audio
    """
    system_instruction = f"""**Persona:** You are a real-time, high-fidelity audio translator. Your only function is to listen to spoken English and immediately translate it into spoken Korean.

**Core Directive:** Translate new English audio input into Korean audio output. Your translation must be immediate, precise, and reflect the vocal delivery of the speaker.

**Rules of Operation:**
1. **Input Language:** You will only receive audio input in English.
2. **Output Language:** You must only produce audio output in Korean.
3. **Real-Time Translation:** Translate only the new words and phrases you hear since your last translation. Do not wait for the speaker to finish a long sentence. Translate incrementally as the speaker talks.
4. **Vocal Replication:** Your primary goal is to replicate the speaker's vocal characteristics in your translated speech. This includes:
   * **Pacing and Speed:** Match the speaker's rate of speech.
   * **Intonation and Tone:** Mirror the rise and fall of the speaker's voice, including emotional tone.
   * **Cadence and Rhythm:** Emulate the speaker's natural speech patterns.
5. **No Extraneous Content:**
   * Do not add any commentary, explanations, or answers.
   * Do not ask questions.
   * Do not engage in conversation.
   * If the speaker asks you a question, translate the question into Korean and do not answer it.

**Strict Protocol Adherence:**
* **Warning:** Any deviation from this translation-only function is a critical failure. Generating any content that is not a direct, incremental translation will result in immediate termination of the session.
* **Important:** You are a translation conduit, not an assistant. Under no circumstances are you to generate original content. Your sole purpose is to provide a seamless and accurate real-time audio translation that preserves the vocal nuances of the original speaker.
"""

    return LiveConnectConfig(
        response_modalities=["AUDIO"],
        # ⭐ Key: Enable proactive audio for continuous translation
        proactivity=ProactivityConfig(proactive_audio=True),
        enable_affective_dialog=False,
        input_audio_transcription=AudioTranscriptionConfig(),
        output_audio_transcription=AudioTranscriptionConfig(),
        speech_config=SpeechConfig(
            voice_config=VoiceConfig(
                prebuilt_voice_config=PrebuiltVoiceConfig(voice_name=voice_name)
            )
        ),
        system_instruction=system_instruction,
    )


def get_s2st_config(target_language="ko"):
    """Config for S2ST model - simultaneous translation mode (Private Preview)."""
    return LiveConnectConfig(
        response_modalities=["AUDIO"],
        speech_config=SpeechConfig(language_code=target_language),
        input_audio_transcription=AudioTranscriptionConfig(),
        output_audio_transcription=AudioTranscriptionConfig(),
    )


# =============================================================================
# GeminiClient Class
# =============================================================================

class GeminiClient:
    """
    Client for Google Gemini Live API.

    Supports two modes:
    - native-audio: Real-time translation with proactive audio (default, uses Gemini API)
    - s2st: Simultaneous translation (requires Vertex AI + Google approval)
    """

    SESSION_TIMEOUT = 14 * 60  # 14 minutes

    def __init__(self):
        # Load API key
        self.api_key = SecureStorage.get_api_key()

        # Load settings
        self.source_language = settings.get("translation", "language_from", "en")
        self.target_language = settings.get("translation", "language_to", "ko")
        model_setting = settings.get("translation", "model", "native-audio")

        # Vertex AI settings (only for s2st mode)
        self.use_vertex_ai = settings.get("translation", "use_vertex_ai", False)
        self.vertex_project = settings.get("translation", "vertex_project") or os.environ.get("GOOGLE_CLOUD_PROJECT")
        self.vertex_location = settings.get("translation", "vertex_location") or os.environ.get("GOOGLE_CLOUD_LOCATION", "us-central1")

        # Determine model mode
        self._setup_model(model_setting)

        # State
        self.client = None
        self.session = None
        self.is_connected = False
        self.session_start_time = None
        self._reconnecting = False

        # Flag to pause input during model response (prevents interruption)
        self._model_responding = False

        # Callbacks for transcriptions
        self.on_input_transcription = None
        self.on_output_transcription = None

        # Initialize client
        self._init_client()

    def _setup_model(self, model_setting):
        """Setup model based on config setting."""
        model_lower = model_setting.lower()

        if "s2st" in model_lower:
            self.mode = "s2st"
            self.model_name = MODEL_S2ST
            self.config = get_s2st_config(self.target_language)
            # S2ST requires Vertex AI
            self.use_vertex_ai = True
        else:
            # Default to native-audio with proactive translation (Gemini API)
            self.mode = "native-audio"
            self.model_name = MODEL_NATIVE_AUDIO
            self.config = get_native_audio_config(
                source_language=self.source_language,
                target_language=self.target_language
            )

        backend = "Vertex AI" if self.use_vertex_ai else "Gemini API"
        print(f"=== Gemini Live API Configuration ===")
        print(f"  Mode: {self.mode}")
        print(f"  Model: {self.model_name}")
        print(f"  Translation: {self.source_language} → {self.target_language}")
        print(f"  Backend: {backend}")
        if self.mode == "native-audio":
            print(f"  Proactive Audio: ENABLED (continuous translation)")

    def _init_client(self):
        """Initialize client based on configuration."""
        if self.use_vertex_ai:
            self._init_vertex_ai_client()
        else:
            self._init_gemini_api_client()

    def _init_vertex_ai_client(self):
        """Initialize Vertex AI client (for S2ST mode)."""
        if not self.vertex_project:
            print("ERROR: Vertex AI requires project ID.")
            print("  Set GOOGLE_CLOUD_PROJECT env var or vertex_project in config.yaml")
            return

        try:
            # Check for service account file
            sa_file = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
            if sa_file and os.path.exists(sa_file):
                from google.oauth2.service_account import Credentials
                credentials = Credentials.from_service_account_file(
                    sa_file,
                    scopes=["https://www.googleapis.com/auth/cloud-platform"]
                )
                self.client = genai.Client(
                    vertexai=True,
                    project=self.vertex_project,
                    location=self.vertex_location,
                    credentials=credentials,
                    http_options=HttpOptions(api_version="v1")
                )
                print(f"  Auth: Service Account")
            else:
                # Use Application Default Credentials (ADC)
                self.client = genai.Client(
                    vertexai=True,
                    project=self.vertex_project,
                    location=self.vertex_location,
                    http_options=HttpOptions(api_version="v1")
                )
                print(f"  Auth: ADC (gcloud)")

            print(f"  Project: {self.vertex_project}")
            print(f"  Location: {self.vertex_location}")
            print(f"================================")
        except Exception as e:
            print(f"Failed to initialize Vertex AI client: {e}")
            traceback.print_exc()
            self.client = None

    def _init_gemini_api_client(self):
        """Initialize Gemini API client (for native-audio mode)."""
        if not self.api_key:
            print("ERROR: No API key found.")
            print("  Set your Gemini API key in the settings.")
            return

        try:
            self.client = genai.Client(
                api_key=self.api_key,
                http_options={"api_version": "v1alpha"}
            )
            print(f"  Auth: API Key")
            print(f"================================")
        except Exception as e:
            print(f"Failed to initialize Gemini API client: {e}")
            traceback.print_exc()
            self.client = None

    async def connect(self):
        """Prepare the client for streaming."""
        if not self.client:
            self._init_client()
            if not self.client:
                raise ValueError("Failed to initialize client")

        self.is_connected = True
        print(f"Ready to stream with {self.mode} mode")

    async def stream_audio(self, audio_queue, sample_rate=16000):
        """Stream audio to Live API and yield responses."""
        while self.is_connected:
            try:
                self._reconnecting = False
                async for item in self._stream_session(audio_queue):
                    yield item
            except SessionExpiredError:
                print("Session expired, reconnecting...")
                await asyncio.sleep(1)
                continue
            except Exception as e:
                if not self.is_connected:
                    break
                print(f"Stream ended: {e}")
                break

    async def _stream_session(self, audio_queue):
        """Single streaming session."""
        if not self.client:
            print("Client not initialized")
            return

        try:
            print(f"Connecting to Live API...")
            print(f"  Mode: {self.mode}")

            async with self.client.aio.live.connect(
                model=self.model_name,
                config=self.config
            ) as session:
                self.session = session
                self.session_start_time = time.time()
                print("Connected!")

                out_queue = asyncio.Queue(maxsize=5)

                send_task = asyncio.create_task(self._send_audio(session, out_queue))
                listen_task = asyncio.create_task(self._queue_audio(audio_queue, out_queue))

                try:
                    # Dispatch to appropriate receive handler
                    if self.mode == "s2st":
                        async for item in self._receive_s2st(session):
                            yield item
                    else:
                        async for item in self._receive_native_audio(session):
                            yield item
                finally:
                    send_task.cancel()
                    listen_task.cancel()
                    try:
                        await send_task
                        await listen_task
                    except asyncio.CancelledError:
                        pass

        except Exception as e:
            if self.is_connected:
                print(f"Connection error: {e}")
                traceback.print_exc()
            raise

    async def _receive_native_audio(self, session):
        """Receive handler for native-audio mode with transcription support."""
        response_count = 0
        while True:
            turn = session.receive()
            async for response in turn:
                response_count += 1

                # Check for server_content (contains transcriptions)
                if hasattr(response, 'server_content') and response.server_content:
                    sc = response.server_content

                    # Input transcription (original English)
                    if hasattr(sc, 'input_transcription') and sc.input_transcription:
                        if text := getattr(sc.input_transcription, 'text', None):
                            print(f"  [INPUT] {text}")
                            yield ("input_transcription", text)

                    # Output transcription (translated Korean)
                    if hasattr(sc, 'output_transcription') and sc.output_transcription:
                        if text := getattr(sc.output_transcription, 'text', None):
                            print(f"  [OUTPUT] {text}")
                            yield ("output_transcription", text)

                    # Audio from model_turn.parts
                    if hasattr(sc, 'model_turn') and sc.model_turn:
                        if parts := getattr(sc.model_turn, 'parts', None):
                            for part in parts:
                                if hasattr(part, 'inline_data') and part.inline_data:
                                    audio_data = part.inline_data.data
                                    if isinstance(audio_data, str):
                                        import base64
                                        audio_data = base64.b64decode(audio_data)
                                    print(f"  [AUDIO] {len(audio_data)} bytes")
                                    yield ("audio", audio_data)
                    continue

                # Fallback: direct data/text attributes
                if data := response.data:
                    print(f"  [AUDIO] {len(data)} bytes")
                    yield ("audio", data)
                    continue

                if text := response.text:
                    print(f"  [TEXT] {text}")
                    yield ("text", text)

            print(f"Turn complete ({response_count} responses)")

    async def _receive_s2st(self, session):
        """Receive handler for S2ST mode."""
        response_count = 0
        while True:
            turn = session.receive()
            async for response in turn:
                response_count += 1

                # S2ST uses server_content structure
                if hasattr(response, 'server_content') and response.server_content:
                    sc = response.server_content

                    # Input transcription (original language)
                    if hasattr(sc, 'input_transcription') and sc.input_transcription:
                        if text := getattr(sc.input_transcription, 'text', None):
                            print(f"  [INPUT] {text}")
                            yield ("input_transcription", text)
                            if self.on_input_transcription:
                                self.on_input_transcription(text)

                    # Output transcription (translated)
                    if hasattr(sc, 'output_transcription') and sc.output_transcription:
                        if text := getattr(sc.output_transcription, 'text', None):
                            print(f"  [OUTPUT] {text}")
                            yield ("output_transcription", text)
                            if self.on_output_transcription:
                                self.on_output_transcription(text)

                    # Audio parts
                    if hasattr(sc, 'model_turn') and sc.model_turn:
                        if parts := getattr(sc.model_turn, 'parts', None):
                            for part in parts:
                                if hasattr(part, 'inline_data') and part.inline_data:
                                    audio_data = part.inline_data.data
                                    if isinstance(audio_data, str):
                                        import base64
                                        audio_data = base64.b64decode(audio_data)
                                    print(f"  [AUDIO] {len(audio_data)} bytes")
                                    yield ("audio", audio_data)
                    continue

                # Fallback: check standard attributes
                if data := response.data:
                    print(f"  [AUDIO] {len(data)} bytes")
                    yield ("audio", data)
                elif text := response.text:
                    print(f"  [TEXT] {text}")
                    yield ("text", text)

            print(f"Turn complete ({response_count} responses)")

    async def _queue_audio(self, audio_queue, out_queue):
        """Read from capture queue and forward to send queue."""
        try:
            while True:
                try:
                    item = await asyncio.wait_for(audio_queue.get(), timeout=0.1)
                except asyncio.TimeoutError:
                    continue

                # Handle tuple (data, rms) from capture
                audio_data = item[0] if isinstance(item, tuple) else item

                # Convert float32 to int16 bytes
                if hasattr(audio_data, 'tobytes'):
                    if getattr(audio_data, 'dtype', None) == np.float32:
                        audio_data = np.clip(audio_data, -1.0, 1.0)
                        audio_data = (audio_data * 32767).astype(np.int16)
                    audio_data = audio_data.tobytes()

                await out_queue.put({"data": audio_data, "mime_type": "audio/pcm"})
        except asyncio.CancelledError:
            pass

    async def _send_audio(self, session, out_queue):
        """Send audio chunks to the API."""
        send_count = 0

        try:
            while True:
                msg = await out_queue.get()
                # Send audio as Blob
                audio_blob = types.Blob(data=msg["data"], mime_type=msg["mime_type"])
                await session.send_realtime_input(audio=audio_blob)
                send_count += 1

                if send_count % 100 == 0:
                    print(f"Sent {send_count} chunks")

        except asyncio.CancelledError:
            print(f"Send complete ({send_count} chunks)")

    # =========================================================================
    # Buffered Mode - Using generateContent API (folubebe style)
    # =========================================================================

    async def stream_audio_buffered(self, audio_queue, sample_rate=16000, buffer_duration=5.0):
        """
        Stream audio with buffering using generateContent API.

        Based on folubebe/gemini_realtime_speech_to_text approach:
        - Collect audio for buffer_duration seconds
        - Send as single request to generateContent API
        - Get transcription + translation
        - Repeat

        This avoids Live API's turn-based limitations.
        """
        import base64
        import io
        import wave

        self.buffer_manager = BufferedAudioManager(
            buffer_duration=buffer_duration,
            sample_rate=sample_rate
        )

        # Gemini 2.5 Flash - good balance of speed and quality
        # Tested: 2.0 (fastest), 2.5 (balanced), 3.0 (too slow)
        buffered_model = "gemini-2.5-flash"

        # Simple prompt for STT + Translation in one call
        translation_prompt = """Transcribe the English audio and translate to Korean.

Format:
[EN] <transcription>
[KO] <translation>

If silence: [EN] (silence) / [KO] (무음)"""

        print(f"Starting BUFFERED mode (generateContent API)...")
        print(f"  Buffer duration: {buffer_duration}s")
        print(f"  Model: {buffered_model}")

        # Start buffer collection task
        buffer_task = asyncio.create_task(
            self._collect_audio_to_buffer(audio_queue)
        )

        buffer_count = 0

        try:
            while self.is_connected:
                # Get next buffer
                buffer = await self.buffer_manager.get_next_buffer(timeout=1.0)

                if buffer is None:
                    if not self.is_connected:
                        break
                    continue

                buffer_count += 1
                print(f"[BUFFER] Processing #{buffer_count}: {len(buffer)} bytes")

                # Convert PCM to WAV in memory
                wav_buffer = io.BytesIO()
                with wave.open(wav_buffer, 'wb') as wav_file:
                    wav_file.setnchannels(1)
                    wav_file.setsampwidth(2)  # 16-bit
                    wav_file.setframerate(sample_rate)
                    wav_file.writeframes(buffer)

                wav_data = wav_buffer.getvalue()
                audio_base64 = base64.b64encode(wav_data).decode('utf-8')

                # Send to generateContent API for STT + Translation
                try:
                    response = await asyncio.to_thread(
                        self.client.models.generate_content,
                        model=buffered_model,
                        contents=[
                            translation_prompt,
                            types.Part.from_bytes(
                                data=wav_data,
                                mime_type="audio/wav"
                            )
                        ]
                    )

                    if response.text:
                        text = response.text.strip()
                        print(f"[RESPONSE] {text}")

                        # Parse response
                        for line in text.split('\n'):
                            line = line.strip()
                            if line.startswith('[EN]'):
                                en_text = line[4:].strip()
                                if en_text and en_text != '(silence)':
                                    yield ("input_transcription", en_text)
                            elif line.startswith('[KO]'):
                                ko_text = line[4:].strip()
                                if ko_text and ko_text != '(무음)':
                                    yield ("output_transcription", ko_text)

                except Exception as e:
                    print(f"[ERROR] generateContent failed: {e}")
                    continue

        except asyncio.CancelledError:
            pass
        finally:
            buffer_task.cancel()
            try:
                await buffer_task
            except asyncio.CancelledError:
                pass
            await self.buffer_manager.shutdown()

    async def _collect_audio_to_buffer(self, audio_queue):
        """Continuously collect audio from capture queue into buffer manager."""
        try:
            while True:
                try:
                    item = await asyncio.wait_for(audio_queue.get(), timeout=0.1)
                except asyncio.TimeoutError:
                    continue

                # Handle tuple (data, rms) from capture
                audio_data = item[0] if isinstance(item, tuple) else item

                # Convert float32 to int16 bytes
                if hasattr(audio_data, 'tobytes'):
                    if getattr(audio_data, 'dtype', None) == np.float32:
                        audio_data = np.clip(audio_data, -1.0, 1.0)
                        audio_data = (audio_data * 32767).astype(np.int16)
                    audio_data = audio_data.tobytes()

                # Add to buffer manager
                await self.buffer_manager.add_chunk(audio_data)

        except asyncio.CancelledError:
            # Flush remaining audio on shutdown
            await self.buffer_manager.flush()

    def disconnect(self):
        """Disconnect from the API."""
        self.is_connected = False
