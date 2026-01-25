import sounddevice as sd
import numpy as np
import asyncio
from typing import Optional

# Gemini outputs 24kHz audio
OUTPUT_SAMPLE_RATE = 24000

class AudioPlayback:
    """
    Plays audio data through selected output device.
    Uses continuous streaming for gapless playback (like official example).
    """

    def __init__(self, device_id: Optional[int] = None, sample_rate: int = OUTPUT_SAMPLE_RATE):
        self.device_id = device_id
        self.sample_rate = sample_rate
        self.volume = 0.8
        self.muted = False
        self._audio_queue = asyncio.Queue()
        self._playback_task = None
        self._stream = None

    def set_device(self, device_id: int):
        """Set output device."""
        self.device_id = device_id

    def set_volume(self, volume: float):
        """Set volume (0.0 to 1.0)."""
        self.volume = max(0.0, min(1.0, volume))

    def set_muted(self, muted: bool):
        """Set mute state."""
        self.muted = muted

    def toggle_mute(self) -> bool:
        """Toggle mute and return new state."""
        self.muted = not self.muted
        return self.muted

    async def start(self):
        """Start playback loop."""
        if self._playback_task and not self._playback_task.done():
            return
        self._playback_task = asyncio.create_task(self._playback_loop())

    async def stop(self):
        """Stop playback."""
        if self._playback_task:
            self._playback_task.cancel()
            try:
                await self._playback_task
            except asyncio.CancelledError:
                pass
            self._playback_task = None

        if self._stream:
            self._stream.close()
            self._stream = None

    async def queue_audio(self, audio_data: bytes):
        """Add audio data to playback queue."""
        await self._audio_queue.put(audio_data)

    async def _playback_loop(self):
        """
        Continuously play queued audio using a persistent output stream.
        Based on official Gemini cookbook example pattern.
        """
        try:
            # Open persistent output stream (like official example)
            self._stream = sd.OutputStream(
                samplerate=self.sample_rate,
                channels=1,
                dtype=np.float32,
                device=self.device_id,
            )
            self._stream.start()
            print(f"Audio playback started (device={self.device_id}, rate={self.sample_rate})")

            while True:
                audio_data = await self._audio_queue.get()

                if self.muted or self.volume == 0:
                    continue

                try:
                    # Convert bytes to numpy array (16-bit PCM from Gemini)
                    audio_array = np.frombuffer(audio_data, dtype=np.int16)
                    # Normalize to float32 and apply volume
                    audio_float = (audio_array.astype(np.float32) / 32768.0 * self.volume).reshape(-1, 1)

                    # Write to stream (non-blocking continuous playback)
                    await asyncio.to_thread(self._stream.write, audio_float)

                except Exception as e:
                    print(f"Playback error: {e}")

        except asyncio.CancelledError:
            pass
        finally:
            if self._stream:
                self._stream.stop()
                self._stream.close()
                self._stream = None
            print("Audio playback stopped")
