import sys
import asyncio
from PyQt6.QtWidgets import QApplication
from qasync import QEventLoop
from src.ui.main_window import MainWindow

def main():
    """
    Main entry point of the LiveNote application.
    Initializes the QApplication and asyncio event loop using qasync.
    """
    app = QApplication(sys.argv)
    loop = QEventLoop(app)
    asyncio.set_event_loop(loop)
    
    window = MainWindow()
    window.show()
    
    with loop:
        loop.run_forever()

if __name__ == "__main__":
    main()
