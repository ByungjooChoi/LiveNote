import { Blob } from '@google/genai';

/**
 * Converts a Float32Array (Web Audio API standard) to Int16Array (PCM)
 * and then encodes it to a base64 string.
 */
export function float32ToB64PCM(float32Arr: Float32Array): string {
  const int16Arr = new Int16Array(float32Arr.length);
  const len = float32Arr.length;
  for (let i = 0; i < len; i++) {
    // Clamp and scale
    const s = Math.max(-1, Math.min(1, float32Arr[i]));
    int16Arr[i] = s < 0 ? s * 0x8000 : s * 0x7FFF;
  }
  
  let binary = '';
  const bytes = new Uint8Array(int16Arr.buffer);
  const byteLen = bytes.byteLength;
  for (let i = 0; i < byteLen; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary);
}

/**
 * Creates a Blob object compatible with Gemini Live API from Float32Array
 */
export function createAudioBlob(data: Float32Array): Blob {
  return {
    data: float32ToB64PCM(data),
    mimeType: 'audio/pcm;rate=16000',
  };
}

/**
 * Decodes a base64 string to a Uint8Array
 */
export function base64ToUint8Array(base64: string): Uint8Array {
  const binaryString = atob(base64);
  const len = binaryString.length;
  const bytes = new Uint8Array(len);
  for (let i = 0; i < len; i++) {
    bytes[i] = binaryString.charCodeAt(i);
  }
  return bytes;
}

/**
 * Converts raw Int16 PCM bytes (from Gemini) to an AudioBuffer for playback.
 */
export function pcmToAudioBuffer(
  pcmData: Uint8Array,
  audioContext: AudioContext
): AudioBuffer {
  // Convert Int16 bytes to Float32 samples
  const int16 = new Int16Array(pcmData.buffer);
  const float32 = new Float32Array(int16.length);
  
  for (let i = 0; i < int16.length; i++) {
    float32[i] = int16[i] / 32768.0;
  }

  // Create buffer (Gemini output is 24kHz mono)
  const buffer = audioContext.createBuffer(1, float32.length, 24000);
  buffer.getChannelData(0).set(float32);
  return buffer;
}

/**
 * Calculates RMS volume for visualization
 */
export function calculateRMS(data: Float32Array): number {
  let sum = 0;
  for (let i = 0; i < data.length; i++) {
    sum += data[i] * data[i];
  }
  return Math.sqrt(sum / data.length);
}
