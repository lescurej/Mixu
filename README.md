# Mixu - Audio Loopback Router

A professional macOS audio routing application built with SwiftUI and Core Audio. Mixu provides a visual patchbay interface for routing audio between input and output devices with real-time audio processing capabilities.

## Features

### 🎛️ Visual Patchbay Interface
- **Drag-and-drop connections**: Create audio routes by dragging from output ports to input ports
- **Multi-selection**: Select multiple connections with Shift+click or marquee selection
- **Real-time visual feedback**: Connections highlight on hover and selection
- **Keyboard shortcuts**: Delete selected connections with Backspace/Delete key

### 🔊 Audio Processing
- **Real-time audio routing**: Low-latency audio streaming between devices
- **Sample rate conversion**: Automatic format conversion between different devices
- **Ring buffer management**: Lock-free audio buffering with overflow protection
- **Test tone generation**: Built-in 440Hz sine wave generator for testing connections

### 🎤 Device Management
- **Automatic device discovery**: Scans and lists all available audio devices
- **Input/Output separation**: Clear distinction between input sources and output destinations
- **Pass-through device support**: Special handling for virtual audio devices (BlackHole)
- **Device format detection**: Automatically detects and adapts to device capabilities

## Architecture

### Core Components

#### Audio Engine (`RouterEngine.swift`)
- Central audio routing coordinator
- Manages audio connections and device lifecycle
- Handles sample rate conversion and format adaptation
- Implements connection creation/removal logic

#### Device Management (`AudioDeviceManager.swift`)
- Core Audio device enumeration and discovery
- Device property querying (sample rates, channel counts, UIDs)
- Device ID to UID mapping for reliable device identification

#### Audio Processing
- **`InputDevice.swift`**: Real device input capture with test tone fallback
- **`OutputSink.swift`**: Multi-device output with format conversion
- **`AudioRingBuffer.swift`**: Thread-safe circular buffer for audio data
- **`StreamFormat.swift`**: Audio format definitions and conversions

#### User Interface
- **`PatchbayView.swift`**: Main patchbay interface with drag-and-drop
- **`DeviceBoxView.swift`**: Individual device representation with ports
- **`ConnectionView.swift`**: Visual connection rendering and interaction
- **`KeyCatcher.swift`**: Keyboard event handling
- **`MarqueeSelection.swift`**: Multi-selection rectangle functionality

## Technical Details

### Audio Format
- **Sample Rate**: 48kHz (configurable)
- **Bit Depth**: 32-bit float
- **Channels**: Stereo (2 channels)
- **Format**: Interleaved PCM

### Performance Features
- **Lock-free ring buffers**: OSAllocatedUnfairLock for thread safety
- **Adaptive buffering**: Dynamic buffer management to prevent underruns
- **Format conversion**: AVAudioConverter for sample rate conversion
- **Noise gating**: Automatic removal of low-level noise

### Dependencies
- **Core Audio**: Low-level audio device access
- **AudioToolbox**: Audio Unit management
- **AVFoundation**: High-level audio processing
- **SwiftUI**: Modern declarative UI framework

## Requirements

- **macOS**: 12.0 or later
- **Xcode**: 14.0 or later
- **Swift**: 5.7 or later
- **Audio Hardware**: Any Core Audio compatible device

## Installation

1. Clone the repository:
```bash
git clone https://github.com/yourusername/mixu.git
cd mixu
```

2. Open in Xcode:
```bash
open Mixu.xcodeproj
```

3. Build and run (⌘+R)

## Usage

### Creating Audio Routes
1. Launch Mixu
2. Input devices appear on the left with output ports (blue circles)
3. Output devices appear on the right with input ports (green circles)
4. Drag from an output port to an input port to create a connection
5. The connection will be established immediately

### Managing Connections
- **Select**: Click on a connection to select it
- **Multi-select**: Hold Shift while clicking to select multiple connections
- **Marquee select**: Drag to create a selection rectangle
- **Delete**: Select connections and press Delete/Backspace

### Device Types
- **Input Devices**: Microphones, audio interfaces, virtual inputs
- **Output Devices**: Speakers, headphones, audio interfaces
- **Pass-through Devices**: Virtual audio devices (like BlackHole) for routing

## Configuration

### Audio Settings
The app uses 48kHz sample rate by default. To modify:
1. Edit `StreamFormat.make()` in `StreamFormat.swift`
2. Update the `inFormat` property in `RouterEngine.swift`

### Device Preferences
- **Pass-through device**: Configure the virtual device name in `RouterEngine.passThruName`
- **Buffer sizes**: Adjust ring buffer capacity in `AudioRingBuffer` initialization

## Troubleshooting

### Common Issues

**No audio devices detected**
- Ensure audio devices are connected and recognized by macOS
- Check System Preferences > Sound for device availability
- Restart the application

**Audio dropouts or glitches**
- Increase buffer size in `AudioRingBuffer` initialization
- Check for CPU-intensive processes
- Verify device sample rate compatibility

**Connection not working**
- Ensure source device has outputs and destination has inputs
- Check device format compatibility
- Verify audio permissions in System Preferences

### Debug Information
The app provides extensive logging:
- Device discovery and binding
- Audio format detection
- Buffer fill levels
- Connection status

## Development

### Project Structure
```
