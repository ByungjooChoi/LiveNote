"""
Gemini Live API - Audio Stream Test
"""
import asyncio
import os
import sys
import numpy as np
from google import genai
from google.genai import types
from dotenv import load_dotenv

sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))
load_dotenv()

API_KEY = os.environ.get("GEMINI_API_KEY")
if not API_KEY:
    try:
        from src.config.secure_storage import SecureStorage
        API_KEY = SecureStorage.get_api_key()
    except ImportError:
        pass

MODEL_NAME = "gemini-2.5-flash-native-audio-preview-12-2025"


def generate_test_audio(duration_sec=2.0, sample_rate=16000):
    """Generate test audio (sine wave) as int16 PCM bytes."""
    t = np.linspace(0, duration_sec, int(sample_rate * duration_sec), dtype=np.float32)
    audio_float = np.sin(2 * np.pi * 440 * t) * 0.3
    audio_int16 = (audio_float * 32767).astype(np.int16)
    return audio_int16.tobytes()


async def test_audio_stream():
    if not API_KEY:
        print("Error: API key not found")
        return
    
    client = genai.Client(api_key=API_KEY, http_options={"api_version": "v1alpha"})
    
    config = types.LiveConnectConfig(
        response_modalities=["AUDIO"],
        speech_config=types.SpeechConfig(
            voice_config=types.VoiceConfig(
                prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Aoede")
            )
        ),
        system_instruction=types.Content(
            parts=[types.Part(text="You are a translator. Listen and respond in Korean.")]
        )
    )
    
    test_audio = generate_test_audio(duration_sec=2.0)
    chunk_size = 2048
    chunks = [test_audio[i:i+chunk_size] for i in range(0, len(test_audio), chunk_size)]
    
    print(f"Generated {len(chunks)} audio chunks")
    
    try:
        async with client.aio.live.connect(model=MODEL_NAME, config=config) as session:
            print("Connected!")
            
            # Send audio
            for i, chunk in enumerate(chunks):
                await session.send_realtime_input(
                    media=types.Blob(data=chunk, mime_type="audio/pcm")
                )
            print(f"Sent {len(chunks)} chunks")
            
            # Send turn_complete with empty text
            await session.send(
                input=types.LiveClientContent(
                    turns=[types.Content(parts=[types.Part(text="")])],
                    turn_complete=True
                )
            )
            print("turn_complete sent!")
            
            # Receive
            response_count = 0
            async for response in session.receive():
                response_count += 1
                print(f"Response #{response_count} received")
                
                if response.server_content:
                    if response.server_content.turn_complete:
                        print("Turn complete received")
                        break
                    
                    if response.server_content.model_turn:
                         for part in response.server_content.model_turn.parts:
                            if part.text:
                                print(f"TEXT: {part.text}")
                            if part.inline_data:
                                print(f"AUDIO: {len(part.inline_data.data)} bytes")

                if response_count > 20:
                    break
                    
    except Exception as e:
        print(f"Error: {e}")
        import traceback
        traceback.print_exc()


if __name__ == "__main__":
    asyncio.run(test_audio_stream())
