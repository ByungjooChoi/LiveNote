import asyncio
import numpy as np
import sounddevice as sd
from scipy import signal

# Target sample rate for Gemini API (same as livenote-web)
TARGET_SAMPLE_RATE = 16000

class AudioCapture:
    """
    Captures real-time audio from a selected input device.
    Resamples to 16kHz for Gemini API (same as livenote-web).
    """

    def __init__(self, device_id, sample_rate=16000, channels=1, buffer_size=1024, silence_threshold=0.005, on_level_update=None):
        self.device_id = device_id
        self.channels = channels
        self.buffer_size = buffer_size
        self.silence_threshold = silence_threshold
        self.on_level_update = on_level_update
        self.queue = asyncio.Queue()
        self.stream = None
        self.is_running = False

        # Always output 16kHz (same as livenote-web)
        self.sample_rate = TARGET_SAMPLE_RATE

        # Native device rate - set on start()
        self._native_sample_rate = None
        self._resample_ratio = 1.0

        try:
            self.loop = asyncio.get_running_loop()
        except RuntimeError:
            self.loop = asyncio.new_event_loop()
            asyncio.set_event_loop(self.loop)

    def _callback(self, indata, frames, time, status):
        """
        Callback function for sounddevice InputStream.
        Resamples audio to 16kHz and puts into the asyncio queue.
        """
        if status:
            print(f"Audio status: {status}")

        # Copy and flatten
        audio_data = indata.copy().flatten()

        # Resample to 16kHz if needed (like livenote-web does in browser)
        if self._resample_ratio != 1.0:
            # Use scipy.signal.resample for high-quality resampling
            target_length = int(len(audio_data) / self._resample_ratio)
            audio_data = signal.resample(audio_data, target_length).astype(np.float32)

        # Calculate RMS
        rms = np.sqrt(np.mean(audio_data**2))

        # Update level meter
        if self.on_level_update:
            db = 20 * np.log10(rms + 1e-10)
            level = max(0, min(100, int((db + 60) * 100 / 60)))
            self.loop.call_soon_threadsafe(self.on_level_update, level)

        # Debug counter
        if not hasattr(self, '_debug_count'):
            self._debug_count = 0
            self._queue_count = 0

        self._debug_count += 1

        # Send ALL audio - let API handle VAD (like official example does)
        # Official pyaudio example doesn't do any VAD filtering
        self._queue_count += 1
        self.loop.call_soon_threadsafe(self.queue.put_nowait, (audio_data, rms))

        if self._debug_count % 100 == 0:
            print(f"Audio callback: {self._debug_count} calls, {self._queue_count} queued, RMS: {rms:.4f}")

    async def start(self):
        """
        Starts the audio capture stream.
        Captures at native rate and resamples to 16kHz (same as livenote-web).
        """
        if self.is_running:
            return

        self.loop = asyncio.get_running_loop()

        try:
            # Get device's native sample rate
            device_info = sd.query_devices(self.device_id, 'input')
            self._native_sample_rate = int(device_info['default_samplerate'])
            self._resample_ratio = self._native_sample_rate / TARGET_SAMPLE_RATE

            print(f"Using audio device: {device_info['name']}")
            print(f"  - Native sample rate: {self._native_sample_rate} Hz")
            print(f"  - Output sample rate: {TARGET_SAMPLE_RATE} Hz (resampled)")
            print(f"  - Resample ratio: {self._resample_ratio:.2f}")
            print(f"  - Max input channels: {device_info['max_input_channels']}")

            # Capture at native rate, resample in callback
            self.stream = sd.InputStream(
                device=self.device_id,
                channels=self.channels,
                samplerate=self._native_sample_rate,
                blocksize=self.buffer_size,
                callback=self._callback
            )
            self.stream.start()
            self.is_running = True
            print(f"Audio capture started on device {self.device_id}")

        except Exception as e:
            print(f"Failed to start audio capture: {e}")
            raise

    def stop(self):
        """
        Stops the audio capture stream.
        """
        if not self.is_running:
            return

        if self.stream:
            self.stream.stop()
            self.stream.close()
            self.stream = None
        
        self.is_running = False
        print("Audio capture stopped")

    async def get_audio_chunk(self):
        """
        Retrieves the next chunk of audio data from the queue.
        
        Returns:
            tuple: (audio_data, rms_level)
        """
        return await self.queue.get()
