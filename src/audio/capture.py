import asyncio
import numpy as np
import sounddevice as sd

class AudioCapture:
    """
    Captures real-time audio from a selected input device.
    """
    
    def __init__(self, device_id, sample_rate=16000, channels=1, buffer_size=1024, silence_threshold=0.01):
        self.device_id = device_id
        self.sample_rate = sample_rate
        self.channels = channels
        self.buffer_size = buffer_size
        self.silence_threshold = silence_threshold
        self.queue = asyncio.Queue()
        self.stream = None
        self.is_running = False
        # Get the running loop or create a new one if not exists (though typically running in async context)
        try:
            self.loop = asyncio.get_running_loop()
        except RuntimeError:
            self.loop = asyncio.new_event_loop()
            asyncio.set_event_loop(self.loop)

    def _callback(self, indata, frames, time, status):
        """
        Callback function for sounddevice InputStream.
        Puts captured audio data into the asyncio queue.
        """
        if status:
            print(f"Audio status: {status}")
        
        # Copy data to avoid buffer issues
        audio_data = indata.copy()
        
        # Calculate audio level (RMS) for VAD or UI visualization
        rms = np.sqrt(np.mean(audio_data**2))
        
        # Simple VAD: Only put in queue if above threshold
        if rms >= self.silence_threshold:
            # Thread-safe queue put
            self.loop.call_soon_threadsafe(self.queue.put_nowait, (audio_data, rms))

    async def start(self):
        """
        Starts the audio capture stream.
        """
        if self.is_running:
            return

        # Ensure we have the correct loop if start is called in a different context
        self.loop = asyncio.get_running_loop()

        try:
            self.stream = sd.InputStream(
                device=self.device_id,
                channels=self.channels,
                samplerate=self.sample_rate,
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
