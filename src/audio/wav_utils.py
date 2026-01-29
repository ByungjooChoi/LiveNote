"""
인메모리 WAV 헤더 생성 유틸리티

Raw PCM 데이터에 44바이트 WAV 헤더를 부착하여
API 호환성을 확보합니다. 디스크 I/O 없이 순수 바이트 연산만 수행합니다.

Based on: Deep Research - Section 3.2.2
"""

import struct


def add_wav_header(
    pcm_data: bytes,
    sample_rate: int = 16000,
    channels: int = 1,
    bit_depth: int = 16
) -> bytes:
    """
    Raw PCM 데이터에 WAV 헤더(44 bytes)를 추가합니다.

    WAV 파일 구조 (RIFF format):
    - Bytes 0-3:   "RIFF" (ChunkID)
    - Bytes 4-7:   File size - 8 (ChunkSize)
    - Bytes 8-11:  "WAVE" (Format)
    - Bytes 12-15: "fmt " (Subchunk1ID)
    - Bytes 16-19: 16 (Subchunk1Size for PCM)
    - Bytes 20-21: 1 (AudioFormat, PCM = 1)
    - Bytes 22-23: NumChannels
    - Bytes 24-27: SampleRate
    - Bytes 28-31: ByteRate
    - Bytes 32-33: BlockAlign
    - Bytes 34-35: BitsPerSample
    - Bytes 36-39: "data" (Subchunk2ID)
    - Bytes 40-43: Data size (Subchunk2Size)
    - Bytes 44+:   Actual audio data

    Args:
        pcm_data: Raw PCM 바이트 데이터 (16-bit signed int, little-endian)
        sample_rate: 샘플 레이트 (기본 16000 Hz)
        channels: 채널 수 (기본 1, Mono)
        bit_depth: 비트 심도 (기본 16)

    Returns:
        WAV 헤더가 붙은 바이트 데이터 (audio/wav MIME 타입으로 전송 가능)

    Example:
        >>> pcm_bytes = capture_audio()  # 16kHz, 16-bit, mono
        >>> wav_bytes = add_wav_header(pcm_bytes)
        >>> # Now send with mime_type="audio/wav"
    """
    byte_rate = sample_rate * channels * (bit_depth // 8)
    block_align = channels * (bit_depth // 8)
    data_size = len(pcm_data)

    # WAV Header (44 bytes) - Little-endian
    header = b'RIFF'
    header += struct.pack('<I', 36 + data_size)  # ChunkSize: 4 + (8 + 16) + (8 + data_size)
    header += b'WAVE'

    # fmt subchunk
    header += b'fmt '
    header += struct.pack('<I', 16)           # Subchunk1Size (16 for PCM)
    header += struct.pack('<H', 1)            # AudioFormat (1 = PCM)
    header += struct.pack('<H', channels)     # NumChannels
    header += struct.pack('<I', sample_rate)  # SampleRate
    header += struct.pack('<I', byte_rate)    # ByteRate
    header += struct.pack('<H', block_align)  # BlockAlign
    header += struct.pack('<H', bit_depth)    # BitsPerSample

    # data subchunk
    header += b'data'
    header += struct.pack('<I', data_size)    # Subchunk2Size

    return header + pcm_data


def get_wav_duration(wav_data: bytes) -> float:
    """
    WAV 데이터의 재생 시간을 계산합니다.

    Args:
        wav_data: WAV 헤더가 포함된 데이터

    Returns:
        재생 시간 (초)
    """
    if len(wav_data) < 44:
        return 0.0

    # 헤더에서 정보 추출
    sample_rate = struct.unpack('<I', wav_data[24:28])[0]
    byte_rate = struct.unpack('<I', wav_data[28:32])[0]
    data_size = struct.unpack('<I', wav_data[40:44])[0]

    if byte_rate == 0:
        return 0.0

    return data_size / byte_rate


def get_pcm_duration(pcm_data: bytes, sample_rate: int = 16000, bit_depth: int = 16, channels: int = 1) -> float:
    """
    Raw PCM 데이터의 재생 시간을 계산합니다.

    Args:
        pcm_data: Raw PCM 바이트 데이터
        sample_rate: 샘플 레이트 (기본 16000 Hz)
        bit_depth: 비트 심도 (기본 16)
        channels: 채널 수 (기본 1)

    Returns:
        재생 시간 (초)
    """
    bytes_per_sample = (bit_depth // 8) * channels
    total_samples = len(pcm_data) // bytes_per_sample
    return total_samples / sample_rate
