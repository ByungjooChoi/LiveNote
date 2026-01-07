from google import genai
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
                {"name": "gemini-2.0-flash-exp", "displayName": "Gemini 2.0 Flash Live (Exp)"},
                {"name": "gemini-1.5-flash-latest", "displayName": "Gemini 1.5 Flash"},
            ]

        try:
            client = genai.Client(api_key=api_key)
            models = []
            
            # List models using the new SDK
            for m in client.models.list():
                # Filtering logic: check if it's a gemini model
                # New SDK model object usually has .name and .display_name
                name = getattr(m, 'name', '')
                display_name = getattr(m, 'display_name', name)
                
                # Basic filtering
                if 'gemini' in name.lower():
                    models.append({
                        "name": name,
                        "displayName": display_name
                    })
            
            if models:
                ModelFetcher._cached_models = models
            return models

        except Exception as e:
            print(f"Error fetching models: {e}")
            # Return cached or default models on error
            return ModelFetcher._cached_models if ModelFetcher._cached_models else [
                 {"name": "gemini-2.0-flash-exp", "displayName": "Gemini 2.0 Flash Live (Offline/Error)"}
            ]

if __name__ == "__main__":
    print(ModelFetcher.get_models(force_refresh=True))
