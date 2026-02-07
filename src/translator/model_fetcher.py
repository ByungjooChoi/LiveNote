from google import genai
from src.config.secure_storage import SecureStorage

class ModelFetcher:
    """
    Fetches available Gemini models from the Google AI API.
    """
    
    _cached_models = []
    
    # Live API compatible models (may not appear in models.list())
    # See: https://ai.google.dev/gemini-api/docs/models#gemini-2.5-flash-live
    LIVE_API_MODELS = [
        {"name": "gemini-2.5-flash-s2st-exp-11-2025", "displayName": "🎤 Gemini 2.5 Flash S2ST (Full Duplex)", "type": "s2st"},
        {"name": "gemini-2.5-flash-native-audio-preview-12-2025", "displayName": "Gemini 2.5 Flash Native Audio (Dec 2025)", "type": "native-audio"},
        {"name": "gemini-2.0-flash-exp", "displayName": "Gemini 2.0 Flash Live (Exp)", "type": "standard"},
    ]

    @staticmethod
    def get_models(force_refresh=False):
        """
        Retrieves a list of available models.
        
        Args:
            force_refresh (bool): If True, ignores cache and fetches from API.
            
        Returns:
            list: A list of model dictionaries {'name': str, 'displayName': str}.
        """
        if ModelFetcher._cached_models and not force_refresh:
            return ModelFetcher._cached_models

        api_key = SecureStorage.get_api_key()
        if not api_key:
            # Return Live API models + fallback when no API key
            return ModelFetcher.LIVE_API_MODELS + [
                {"name": "gemini-1.5-flash-latest", "displayName": "Gemini 1.5 Flash"},
            ]

        try:
            client = genai.Client(api_key=api_key)
            models = []
            
            # List models using the new SDK
            for m in client.models.list():
                # Filtering logic: check if it's a gemini model
                name = getattr(m, 'name', '')
                display_name = getattr(m, 'display_name', name)
                
                # Basic filtering
                if 'gemini' in name.lower():
                    models.append({
                        "name": name,
                        "displayName": display_name
                    })
            
            # Ensure Live API models are always available (may not be in models.list())
            for live_model in ModelFetcher.LIVE_API_MODELS:
                if not any(m['name'] == live_model['name'] for m in models):
                    models.insert(0, live_model)
            
            if models:
                ModelFetcher._cached_models = models
            return models

        except Exception as e:
            print(f"Error fetching models: {e}")
            # Return cached or default models on error
            return ModelFetcher._cached_models if ModelFetcher._cached_models else ModelFetcher.LIVE_API_MODELS

if __name__ == "__main__":
    print(ModelFetcher.get_models(force_refresh=True))
