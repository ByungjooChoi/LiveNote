"""
Buffered Audio Manager for sequential interpretation with delay tolerance.

This manager buffers audio in fixed-duration chunks (e.g., 5 seconds) and
queues them for processing. Optimized for low latency and memory safety.

Key optimizations:
- Lock-free fast path for adding chunks (uses bytearray for O(1) append)
- Bounded queue with automatic oldest-drop to prevent memory overflow
- Pre-allocated buffer to minimize allocations
- Minimal copying during buffer operations
"""

import asyncio
import time
from collections import deque
from typing import Optional


class BufferedAudioManager:
    """
    Manages audio buffering for sequential interpretation.

    Features:
    - Fixed-duration buffering (default 5 seconds)
    - Bounded queue to prevent memory overflow (max ~100s of audio)
    - Lock-free chunk addition for low latency
    - Automatic cleanup of old buffers when queue is full
    """

    # Safety limits
    MAX_QUEUE_SIZE = 20  # Max pending buffers (20 * 5s = 100s of audio max)
    MAX_BUFFER_BYTES = 2 * 1024 * 1024  # 2MB max per buffer (5s @ 16kHz 16-bit = ~160KB)
    WARN_QUEUE_SIZE = 10  # Warn when queue exceeds this

    def __init__(self, buffer_duration: float = 5.0, sample_rate: int = 16000):
        """
        Initialize the buffer manager.

        Args:
            buffer_duration: Duration of each buffer in seconds
            sample_rate: Audio sample rate in Hz
        """
        self.buffer_duration = buffer_duration
        self.sample_rate = sample_rate

        # Calculate expected buffer size (16-bit audio = 2 bytes per sample)
        self.expected_buffer_size = int(sample_rate * buffer_duration * 2)

        # Use bytearray for O(1) extend operations (faster than list of bytes)
        self._current_buffer = bytearray(self.expected_buffer_size)
        self._current_buffer_pos = 0
        self._buffer_start_time: Optional[float] = None

        # Queue of completed buffers (deque with maxlen auto-drops oldest)
        self._pending_queue: deque[bytes] = deque(maxlen=self.MAX_QUEUE_SIZE)

        # Async event to signal new buffer available
        self._buffer_available = asyncio.Event()

        # Statistics (atomic operations, no lock needed)
        self._buffers_created = 0
        self._buffers_dropped = 0
        self._total_bytes_processed = 0

        # Light lock only for queue operations
        self._queue_lock = asyncio.Lock()

        # Shutdown flag
        self._shutdown = False

    def add_chunk_sync(self, chunk: bytes) -> bool:
        """
        Add an audio chunk to the current buffer (synchronous, lock-free).

        This is the hot path - optimized for speed.

        Args:
            chunk: Raw audio bytes (16-bit PCM)

        Returns:
            True if buffer was flushed, False otherwise
        """
        if self._shutdown:
            return False

        # Start timer on first chunk
        if self._buffer_start_time is None:
            self._buffer_start_time = time.time()

        chunk_len = len(chunk)
        self._total_bytes_processed += chunk_len

        # Fast path: append to bytearray
        new_pos = self._current_buffer_pos + chunk_len

        # Check if we need to resize (rare case)
        if new_pos > len(self._current_buffer):
            # Extend buffer (this is rare, only if chunks are larger than expected)
            self._current_buffer.extend(bytes(new_pos - len(self._current_buffer)))

        # Copy chunk into buffer
        self._current_buffer[self._current_buffer_pos:new_pos] = chunk
        self._current_buffer_pos = new_pos

        # Check if buffer duration reached
        elapsed = time.time() - self._buffer_start_time
        if elapsed >= self.buffer_duration:
            self._flush_buffer_sync()
            return True

        return False

    async def add_chunk(self, chunk: bytes) -> None:
        """Async wrapper for add_chunk_sync."""
        flushed = self.add_chunk_sync(chunk)
        if flushed:
            # Signal that buffer is available (only when flushed)
            self._buffer_available.set()

    def _flush_buffer_sync(self) -> None:
        """Flush current buffer to queue (synchronous)."""
        if self._current_buffer_pos == 0:
            return

        # Extract filled portion of buffer (single copy)
        buffer_data = bytes(self._current_buffer[:self._current_buffer_pos])

        # Sanity check
        if len(buffer_data) > self.MAX_BUFFER_BYTES:
            print(f"[BUFFER] WARNING: Buffer too large ({len(buffer_data)} bytes), truncating")
            buffer_data = buffer_data[:self.MAX_BUFFER_BYTES]

        # Check if queue will overflow
        if len(self._pending_queue) >= self.MAX_QUEUE_SIZE:
            self._buffers_dropped += 1
            print(f"[BUFFER] WARNING: Queue full, will drop oldest (total dropped: {self._buffers_dropped})")

        # Add to queue (deque with maxlen handles overflow automatically)
        self._pending_queue.append(buffer_data)
        self._buffers_created += 1

        queue_size = len(self._pending_queue)
        if queue_size >= self.WARN_QUEUE_SIZE:
            print(f"[BUFFER] Buffer #{self._buffers_created}: {len(buffer_data)} bytes, "
                  f"queue: {queue_size}/{self.MAX_QUEUE_SIZE} (HIGH)")
        else:
            print(f"[BUFFER] Buffer #{self._buffers_created}: {len(buffer_data)} bytes, "
                  f"queue: {queue_size}/{self.MAX_QUEUE_SIZE}")

        # Reset buffer (reuse existing bytearray - no allocation)
        self._current_buffer_pos = 0
        self._buffer_start_time = None

    async def flush(self) -> None:
        """Force flush the current buffer."""
        if self._current_buffer_pos > 0:
            self._flush_buffer_sync()
            self._buffer_available.set()

    async def get_next_buffer(self, timeout: Optional[float] = None) -> Optional[bytes]:
        """
        Get the next buffer from the queue.

        Args:
            timeout: Max time to wait for a buffer (None = wait forever)

        Returns:
            Buffer bytes, or None if timeout/shutdown
        """
        while not self._shutdown:
            # Fast check without lock
            if self._pending_queue:
                async with self._queue_lock:
                    if self._pending_queue:
                        buffer = self._pending_queue.popleft()
                        remaining = len(self._pending_queue)
                        print(f"[BUFFER] Dequeued: {len(buffer)} bytes, remaining: {remaining}")
                        return buffer

            # Wait for new buffer
            self._buffer_available.clear()
            try:
                await asyncio.wait_for(
                    self._buffer_available.wait(),
                    timeout=timeout if timeout is not None else 0.5
                )
            except asyncio.TimeoutError:
                if timeout is not None:
                    return None
                continue

        return None

    def has_pending_buffers(self) -> bool:
        """Check if there are buffers waiting to be sent."""
        return len(self._pending_queue) > 0

    def get_queue_size(self) -> int:
        """Get number of pending buffers."""
        return len(self._pending_queue)

    def get_delay_seconds(self) -> float:
        """Estimate current delay in seconds based on queue size."""
        return len(self._pending_queue) * self.buffer_duration

    def get_stats(self) -> dict:
        """Get buffer statistics."""
        return {
            "buffers_created": self._buffers_created,
            "buffers_dropped": self._buffers_dropped,
            "buffers_pending": len(self._pending_queue),
            "total_bytes": self._total_bytes_processed,
            "current_buffer_bytes": self._current_buffer_pos,
            "estimated_delay_sec": self.get_delay_seconds(),
        }

    async def shutdown(self) -> None:
        """Shutdown the buffer manager and flush remaining data."""
        self._shutdown = True
        await self.flush()
        self._buffer_available.set()  # Wake up any waiters

        stats = self.get_stats()
        print(f"[BUFFER] Shutdown - Created: {stats['buffers_created']}, "
              f"Dropped: {stats['buffers_dropped']}, "
              f"Total: {stats['total_bytes'] / 1024 / 1024:.2f} MB")

    def reset(self) -> None:
        """Reset the buffer manager for a new session."""
        self._current_buffer_pos = 0
        self._buffer_start_time = None
        self._pending_queue.clear()
        self._buffers_created = 0
        self._buffers_dropped = 0
        self._total_bytes_processed = 0
        self._shutdown = False
        self._buffer_available.clear()
