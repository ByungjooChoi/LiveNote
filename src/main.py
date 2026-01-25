import sys
import asyncio
import atexit
from PyQt6.QtWidgets import QApplication
from qasync import QEventLoop
from src.ui.main_window import MainWindow
from src.utils.logger import setup_logging

# Global logger reference
_logger = None

def main():
    """
    Main entry point of the LiveNote application.
    Initializes the QApplication and asyncio event loop using qasync.
    """
    global _logger

    # Initialize logging system first
    _logger = setup_logging()
    atexit.register(_logger.close)

    print("=" * 60)
    print("LiveNote Starting...")
    print("=" * 60)

    app = QApplication(sys.argv)
    loop = QEventLoop(app)
    asyncio.set_event_loop(loop)

    window = MainWindow()
    window.show()

    with loop:
        loop.run_forever()

if __name__ == "__main__":
    main()
