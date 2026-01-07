"""
Gemini Live API Test Script
Purpose: Verify Native Audio model response structure
"""
import asyncio
import os
import sys
import numpy as np
import sounddevice as sd
from google import genai
from google.genai import types
from dotenv import load_dotenv
import traceback

# Add project root to path for imports
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

# Load environment
load_dotenv()

# Attempt to load API key
API_KEY = os.environ.get("GEMINI_API_KEY")
if not API_KEY:
    try:
        from src.config.secure_storage import SecureStorage
        API_KEY = SecureStorage.get_api_key()
    except ImportError:
        pass

MODEL_NAME = "gemini-2.5-flash-native-audio-preview-12-2025"

async def test_live_api():
    """Test Live API connection and response structure."""
    
    if not API_KEY:
        print("Error: GEMINI_API_KEY not found in environment or .env file.")
        return

    client = genai.Client(api_key=API_KEY, http_options={"api_version": "v1alpha"})
    
    # Test different configurations
    configs_to_test = [
        {
            "name": "AUDIO only",
            "config": types.LiveConnectConfig(
                response_modalities=["AUDIO"],
                speech_config=types.SpeechConfig(
                    voice_config=types.VoiceConfig(
                        prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Aoede")
                    )
                ),
                system_instruction=types.Content(
                    parts=[types.Part(text="Say 'Hello, this is a test' in Korean.")]
                )
            )
        },
        {
            "name": "TEXT only",
            "config": types.LiveConnectConfig(
                response_modalities=["TEXT"],
                system_instruction=types.Content(
                    parts=[types.Part(text="Say 'Hello, this is a test' in Korean.")]
                )
            )
        },
        {
            "name": "TEXT and AUDIO",
            "config": types.LiveConnectConfig(
                response_modalities=["TEXT", "AUDIO"],
                speech_config=types.SpeechConfig(
                    voice_config=types.VoiceConfig(
                        prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Aoede")
                    )
                ),
                system_instruction=types.Content(
                    parts=[types.Part(text="Say 'Hello, this is a test' in Korean.")]
                )
            )
        }
    ]
    
    for test_config in configs_to_test:
        print(f"\n{'='*60}")
        print(f"Testing: {test_config['name']}")
        print(f"{'='*60}")
        
        try:
            async with client.aio.live.connect(model=MODEL_NAME, config=test_config['config']) as session:
                print("Connected successfully!")
                
                # Send a simple text message to trigger response
                await session.send(
                    input=types.LiveClientContent(
                        turns=[types.Content(
                            parts=[types.Part(text="Please respond now.")]
                        )],
                        turn_complete=True
                    )
                )
                
                # Receive and analyze responses
                response_count = 0
                async for response in session.receive():
                    response_count += 1
                    print(f"\n--- Response #{response_count} ---")
                    
                    if response.server_content:
                        sc = response.server_content
                        # print(f"server_content attributes: {[a for a in dir(sc) if not a.startswith('_')]}")
                        
                        # Check for model_turn
                        if sc.model_turn:
                            print(f"  model_turn.parts count: {len(sc.model_turn.parts)}")
                            for i, part in enumerate(sc.model_turn.parts):
                                if part.text:
                                    print(f"      [TEXT]: {part.text[:100]}...")
                                if part.inline_data:
                                    print(f"      [AUDIO]: {part.inline_data.mime_type}, {len(part.inline_data.data)} bytes")
                        
                        # Check for transcription attributes (might be different in this SDK version)
                        # We print all non-empty attributes to find it
                        # if hasattr(sc, 'output_transcription'): print(f"  output_transcription: {sc.output_transcription}")
                        
                    # Check turn_complete
                    if response.server_content and response.server_content.turn_complete:
                        print("  turn_complete: True")
                        break
                    
                    if response_count > 10:  # Safety limit
                        print("Reached response limit")
                        break
                        
        except Exception as e:
            print(f"Error: {e}")
            # traceback.print_exc()
        
        await asyncio.sleep(1)  # Wait between tests

if __name__ == "__main__":
    asyncio.run(test_live_api())
