import sys
import asyncio
from PyQt6.QtWidgets import QApplication
from qasync import QEventLoop

def main():
    """
    Main entry point of the LiveNote application.
    Initializes the QApplication and asyncio event loop using qasync.
    """
    app = QApplication(sys.argv)
    loop = QEventLoop(app)
    asyncio.set_event_loop(loop)
    
    # TODO: Initialize main window and modules
    print("LiveNote started...")
    
    with loop:
        loop.run_forever()

if __name__ == "__main__":
    main()
