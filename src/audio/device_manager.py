import sounddevice as sd

class DeviceManager:
    """
    Manages audio devices for the LiveNote application.
    Provides functionality to list and select audio input devices.
    Supports virtual audio devices like BlackHole for system audio capture.
    """

    # Known virtual audio device patterns (for system audio capture)
    VIRTUAL_AUDIO_PATTERNS = [
        'blackhole',
        'loopback',
        'soundflower',
        'virtual',
        'multi-output',
        'zoomaudiodevice',  # Zoom's built-in virtual audio device
    ]

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
                    device_name = device['name']
                    is_virtual = DeviceManager._is_virtual_device(device_name)

                    device_info = {
                        'id': i,
                        'name': device_name,
                        'channels': device['max_input_channels'],
                        'sample_rate': device['default_samplerate'],
                        'hostapi': device['hostapi'],
                        'is_virtual': is_virtual,
                        'is_system_audio': is_virtual,  # Virtual devices capture system audio
                    }
                    devices.append(device_info)

        except Exception as e:
            print(f"Error querying audio devices: {e}")

        return devices

    @staticmethod
    def _is_virtual_device(device_name):
        """Check if device is a virtual audio device."""
        name_lower = device_name.lower()
        return any(pattern in name_lower for pattern in DeviceManager.VIRTUAL_AUDIO_PATTERNS)

    @staticmethod
    def find_blackhole_device():
        """
        Find BlackHole virtual audio device for system audio capture.

        Returns:
            dict or None: BlackHole device info if found, None otherwise.
        """
        devices = DeviceManager.get_input_devices()
        for device in devices:
            if 'blackhole' in device['name'].lower():
                return device
        return None

    @staticmethod
    def find_system_audio_device():
        """
        Find any virtual audio device suitable for system audio capture.
        Prioritizes BlackHole, then Loopback, then others.

        Returns:
            dict or None: Virtual audio device info if found, None otherwise.
        """
        devices = DeviceManager.get_input_devices()
        virtual_devices = [d for d in devices if d.get('is_virtual', False)]

        if not virtual_devices:
            return None

        # Prioritize by device name
        for pattern in ['blackhole', 'zoomaudiodevice', 'loopback', 'soundflower']:
            for device in virtual_devices:
                if pattern in device['name'].lower():
                    return device

        # Return first virtual device found
        return virtual_devices[0]

    @staticmethod
    def get_output_devices():
        """
        Retrieves a list of available audio output devices.
        
        Returns:
            list: A list of dictionaries, each containing device information.
        """
        devices = []
        try:
            sd_devices = sd.query_devices()
            
            for i, device in enumerate(sd_devices):
                # Filter for output devices (max_output_channels > 0)
                if device['max_output_channels'] > 0:
                    device_info = {
                        'id': i,
                        'name': device['name'],
                        'channels': device['max_output_channels'],
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
        print(f"\n{'='*60}")
        print(f"Found {len(devices)} input devices:")
        print(f"{'='*60}")

        # Separate virtual and physical devices
        virtual_devices = [d for d in devices if d.get('is_virtual', False)]
        physical_devices = [d for d in devices if not d.get('is_virtual', False)]

        if virtual_devices:
            print("\n[VIRTUAL AUDIO DEVICES - for system audio capture]")
            for device in virtual_devices:
                print(f"  ★ ID: {device['id']} | {device['name']} | Channels: {device['channels']} | Rate: {device['sample_rate']}")

        if physical_devices:
            print("\n[PHYSICAL DEVICES - microphones]")
            for device in physical_devices:
                print(f"    ID: {device['id']} | {device['name']} | Channels: {device['channels']} | Rate: {device['sample_rate']}")

        # Recommend system audio device
        system_device = DeviceManager.find_system_audio_device()
        if system_device:
            print(f"\n✓ Recommended for system audio: ID {system_device['id']} ({system_device['name']})")
        else:
            print("\n⚠ No virtual audio device found. Install BlackHole for system audio capture:")
            print("  brew install blackhole-2ch")
            print("  Then set up Multi-Output Device in Audio MIDI Setup.")

        print()

if __name__ == "__main__":
    DeviceManager.print_input_devices()
