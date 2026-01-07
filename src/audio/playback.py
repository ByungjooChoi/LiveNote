import sounddevice as sd
import numpy as np
import asyncio
from typing import Optional

class AudioPlayback:
    """Plays audio data through selected output device."""
    
    def __init__(self, device_id: Optional[int] = None, sample_rate: int = 24000):
        self.device_id = device_id
        self.sample_rate = sample_rate
        self.volume = 0.5  # 0.0 to 1.0
        self.muted = False
        self._audio_queue = asyncio.Queue()
        self._playback_task = None
    
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
    
    async def queue_audio(self, audio_data: bytes):
        """Add audio data to playback queue."""
        await self._audio_queue.put(audio_data)
    
    async def _playback_loop(self):
        """Continuously play queued audio."""
        try:
            while True:
                audio_data = await self._audio_queue.get()
                
                if self.muted or self.volume == 0:
                    continue  # Skip playback but consume queue
                
                try:
                    # Convert bytes to numpy array (assuming 16-bit PCM from Gemini)
                    audio_array = np.frombuffer(audio_data, dtype=np.int16)
                    # Normalize and apply volume
                    audio_float = audio_array.astype(np.float32) / 32768.0 * self.volume
                    
                    # Play audio (blocking wait to ensure sequential playback)
                    # Run in thread to avoid blocking asyncio event loop
                    await asyncio.to_thread(self._play_chunk_blocking, audio_float)
                    
                except Exception as e:
                    print(f"Playback error: {e}")
                    
        except asyncio.CancelledError:
            pass

    def _play_chunk_blocking(self, audio_data):
        """Helper to play audio and wait for it to finish."""
        try:
            sd.play(audio_data, self.sample_rate, device=self.device_id)
            sd.wait()
        except Exception as e:
            print(f"Sounddevice error: {e}")
