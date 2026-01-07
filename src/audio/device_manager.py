import sounddevice as sd

class DeviceManager:
    """
    Manages audio devices for the LiveNote application.
    Provides functionality to list and select audio input devices.
    """
    
    @staticmethod
    def get_input_devices():
        """
        Retrieves a list of available audio input devices.
        
        Returns:
            list: A list of dictionaries, each containing device information.
        """
        devices = []
        try:
            # Query all devices available to sounddevice
            sd_devices = sd.query_devices()
            
            for i, device in enumerate(sd_devices):
                # Filter for input devices (max_input_channels > 0)
                if device['max_input_channels'] > 0:
                    device_info = {
                        'id': i,
                        'name': device['name'],
                        'channels': device['max_input_channels'],
                        'sample_rate': device['default_samplerate'],
                        'hostapi': device['hostapi']
                    }
                    devices.append(device_info)
                    
        except Exception as e:
            print(f"Error querying audio devices: {e}")
            
        return devices

    @staticmethod
    def print_input_devices():
        """
        Prints the list of available input devices to the console.
        Useful for debugging.
        """
        devices = DeviceManager.get_input_devices()
        print(f"Found {len(devices)} input devices:")
        for device in devices:
            print(f"ID: {device['id']} | Name: {device['name']} | Channels: {device['channels']} | Rate: {device['sample_rate']}")

if __name__ == "__main__":
    DeviceManager.print_input_devices()
