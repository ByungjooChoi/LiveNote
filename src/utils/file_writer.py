import os
import datetime
from src.config.settings_manager import settings

class FileWriter:
    """
    Handles saving translation transcripts to text files.
    """
    
    def __init__(self):
        self.output_dir = settings.get("output", "save_directory", "output")
        self.filename_format = settings.get("output", "filename_format", "transcript_%Y%m%d_%H%M%S.txt")
        self.current_file = None
        self.ensure_directory()

    def ensure_directory(self):
        if not os.path.exists(self.output_dir):
            os.makedirs(self.output_dir)

    def start_session(self):
        """Creates a new transcript file for the session."""
        # Ensure directory exists in case it was deleted
        self.ensure_directory()
        
        filename = datetime.datetime.now().strftime(self.filename_format)
        filepath = os.path.join(self.output_dir, filename)
        
        try:
            # Open file in append mode, line buffered
            self.current_file = open(filepath, 'a', encoding='utf-8', buffering=1)
            self.write_line(f"--- LiveNote Session Started: {datetime.datetime.now()} ---")
            print(f"Transcript saved to: {filepath}")
            return filepath
        except Exception as e:
            print(f"Failed to create transcript file: {e}")
            self.current_file = None
            return None

    def write_line(self, text, newline=True):
        """Writes a line of text with timestamp.

        Args:
            text: Text to write
            newline: If True, adds newline at the end (default). If False, continues on same line.
        """
        # Skip empty or whitespace-only text
        if not text or not text.strip():
            return

        if self.current_file and not self.current_file.closed:
            timestamp = datetime.datetime.now().strftime("%H:%M:%S")
            try:
                ending = "\n" if newline else ""
                self.current_file.write(f"[{timestamp}] {text}{ending}")
                # Flush ensures data is written even if app crashes
                self.current_file.flush()
            except Exception as e:
                print(f"Error writing to file: {e}")

    def close_session(self):
        """Closes the current file."""
        if self.current_file and not self.current_file.closed:
            self.write_line(f"--- Session Ended: {datetime.datetime.now()} ---")
            self.current_file.close()
            self.current_file = None
