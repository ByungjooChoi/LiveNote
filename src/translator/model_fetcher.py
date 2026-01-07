import google.generativeai as genai
from src.config.secure_storage import SecureStorage

class ModelFetcher:
    """
    Fetches available Gemini models from the Google AI API.
    """
    
    _cached_models = []

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
            # Return default fallback models if no API key is set
            return [
                {"name": "models/gemini-2.5-flash-preview-native-audio-dialog", "displayName": "Gemini 2.5 Flash (Default)"},
                {"name": "models/gemini-2.0-flash-live-001", "displayName": "Gemini 2.0 Flash Live"},
            ]

        try:
            genai.configure(api_key=api_key)
            models = []
            for m in genai.list_models():
                # Basic filtering for Gemini models
                if 'gemini' in m.name.lower() and 'generateContent' in m.supported_generation_methods:
                    models.append({
                        "name": m.name,
                        "displayName": m.display_name
                    })
            
            if models:
                ModelFetcher._cached_models = models
            return models

        except Exception as e:
            print(f"Error fetching models: {e}")
            # Return cached or default models on error
            return ModelFetcher._cached_models if ModelFetcher._cached_models else [
                {"name": "models/gemini-2.5-flash-preview-native-audio-dialog", "displayName": "Gemini 2.5 Flash (Offline/Error)"}
            ]

if __name__ == "__main__":
    print(ModelFetcher.get_models(force_refresh=True))
