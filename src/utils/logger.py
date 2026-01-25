"""
Comprehensive logging system for LiveNote.
Captures all terminal output and saves to log files.
"""

import sys
import os
import logging
from datetime import datetime
from pathlib import Path


class DualOutput:
    """
    Writes to both console and log file simultaneously.
    """
    def __init__(self, log_file, original_stream):
        self.log_file = log_file
        self.original_stream = original_stream

    def write(self, message):
        # Write to original stream (console)
        self.original_stream.write(message)
        self.original_stream.flush()

        # Write to log file (include all messages, even newlines)
        self.log_file.write(message)
        self.log_file.flush()

    def flush(self):
        self.original_stream.flush()
        self.log_file.flush()


class LiveNoteLogger:
    """
    Singleton logger for LiveNote application.
    """
    _instance = None
    _initialized = False

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance

    def __init__(self):
        if LiveNoteLogger._initialized:
            return

        # Create logs directory
        self.log_dir = Path("logs")
        self.log_dir.mkdir(exist_ok=True)

        # Create timestamped log file
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        self.log_path = self.log_dir / f"livenote_{timestamp}.log"

        # Open log file
        self.log_file = open(self.log_path, 'w', encoding='utf-8')

        # Write header
        self.log_file.write(f"{'='*60}\n")
        self.log_file.write(f"LiveNote Log - {datetime.now().isoformat()}\n")
        self.log_file.write(f"{'='*60}\n\n")
        self.log_file.flush()

        # Redirect stdout and stderr
        self._original_stdout = sys.stdout
        self._original_stderr = sys.stderr

        sys.stdout = DualOutput(self.log_file, self._original_stdout)
        sys.stderr = DualOutput(self.log_file, self._original_stderr)

        # Setup Python logging
        self.logger = logging.getLogger('livenote')
        self.logger.setLevel(logging.DEBUG)

        # File handler for detailed logs
        file_handler = logging.FileHandler(self.log_path, encoding='utf-8')
        file_handler.setLevel(logging.DEBUG)
        file_formatter = logging.Formatter(
            '%(asctime)s [%(levelname)s] %(name)s: %(message)s',
            datefmt='%H:%M:%S'
        )
        file_handler.setFormatter(file_formatter)
        self.logger.addHandler(file_handler)

        # Console handler for important messages
        console_handler = logging.StreamHandler(self._original_stdout)
        console_handler.setLevel(logging.INFO)
        console_formatter = logging.Formatter('[%(levelname)s] %(message)s')
        console_handler.setFormatter(console_formatter)
        self.logger.addHandler(console_handler)

        LiveNoteLogger._initialized = True

        print(f"Logging to: {self.log_path}")

    def get_logger(self, name=None):
        """Get a logger instance."""
        if name:
            return logging.getLogger(f'livenote.{name}')
        return self.logger

    def close(self):
        """Clean up logging resources."""
        if self.log_file:
            self.log_file.write(f"\n{'='*60}\n")
            self.log_file.write(f"Session ended: {datetime.now().isoformat()}\n")
            self.log_file.write(f"{'='*60}\n")
            self.log_file.flush()
            self.log_file.close()

        # Restore original streams
        sys.stdout = self._original_stdout
        sys.stderr = self._original_stderr


def setup_logging():
    """Initialize the logging system."""
    return LiveNoteLogger()


def get_logger(name=None):
    """Get a logger instance."""
    return LiveNoteLogger().get_logger(name)
