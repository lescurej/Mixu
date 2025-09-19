//
//  AudioDeviceManager.swift
//  Mixu
//
//  Created by Johan Lescure on 15/09/2025.
//

import AudioToolbox
import CoreAudio

// MARK: - AudioDevice Query Helpers
struct AudioDevice {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let numOutputs: Int
    let numInputs: Int
}

enum DeviceScope {
    case input
    case output
}

final class AudioDeviceManager {
    func allDevices() -> [AudioDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(0), count: count)

        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs)
        guard status == noErr else { return [] }

        return deviceIDs.compactMap { deviceInfo(deviceID: $0) }
    }

    func deviceInfo(deviceID: AudioDeviceID) -> AudioDevice? {
        func stringProperty(_ selector: AudioObjectPropertySelector) -> String? {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            var dataSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else {
                return nil
            }

            var cfString: CFString? = nil
            let status = withUnsafeMutablePointer(to: &cfString) { ptr in
                AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, ptr)
            }

            guard status == noErr, let value = cfString else { return nil }
            return value as String
        }

        func channelCount(for scope: DeviceScope) -> Int {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: (scope == .input) ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )

            var dataSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else {
                return 0
            }
            
            // Add safety checks
            guard dataSize > 0 else { return 0 }
            guard dataSize >= MemoryLayout<AudioBufferList>.size else { return 0 }
            
            let maximumBuffers = Int(dataSize) / MemoryLayout<AudioBuffer>.stride
            guard maximumBuffers > 0 else { return 0 }
                        
            let audioBufferList = AudioBufferList.allocate(maximumBuffers: maximumBuffers)
            defer { free(audioBufferList.unsafeMutablePointer) }

            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, audioBufferList.unsafeMutablePointer)
            guard status == noErr else { return 0 }

            var channels = 0
            for buffer in audioBufferList {
                channels += Int(buffer.mNumberChannels)
            }
            return channels
        }

        guard
            let name = stringProperty(kAudioObjectPropertyName),
            let uid = stringProperty(kAudioDevicePropertyDeviceUID)
        else {
            return nil
        }

        let outputs = channelCount(for: .output)
        let inputs = channelCount(for: .input)

        return AudioDevice(id: deviceID, name: name, uid: uid, numOutputs: outputs, numInputs: inputs)
    }

    func findDevice(byName name: String) -> AudioDevice? {
        allDevices().first { $0.name.contains(name) }
    }

    func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var uidString: CFString = uid as CFString

        var translation = AudioValueTranslation(
            mInputData: withUnsafePointer(to: &uidString) { UnsafeMutableRawPointer(mutating: $0) },
            mInputDataSize: UInt32(MemoryLayout<CFString>.size),
            mOutputData: UnsafeMutableRawPointer(&deviceID),
            mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        var dataSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
        let status = withUnsafeMutablePointer(to: &translation) { translationPointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, translationPointer)
        }

        if status == noErr && deviceID != 0 {
            // Add device validation
            var isAlive: UInt32 = 0
            var aliveAddress = AudioObjectPropertyAddress(
                mSelector: 0x616C6976, // 'aliv' - kAudioObjectPropertyIsAlive
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var aliveDataSize = UInt32(MemoryLayout<UInt32>.size)
            let aliveStatus = AudioObjectGetPropertyData(deviceID, &aliveAddress, 0, nil, &aliveDataSize, &isAlive)
            
            if aliveStatus == noErr && isAlive != 0 {
                return deviceID
            }
        }
        return allDevices().first(where: { $0.uid == uid })?.id
    }

    func debugDeviceInfo(deviceID: AudioDeviceID) {
        print("=== Device Debug Info for ID: \(deviceID) ===")
        
        // Get device name
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        if AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr {
            var cfString: CFString? = nil
            let status = withUnsafeMutablePointer(to: &cfString) { ptr in
                AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, ptr)
            }
            if status == noErr, let name = cfString {
                print("Device name: \(name)")
            }
        }
        
        // Check if device is alive
        var isAlive: UInt32 = 0
        address.mSelector = 0x616C6976 // 'aliv'
        var aliveDataSize = UInt32(MemoryLayout<UInt32>.size)
        let aliveStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &aliveDataSize, &isAlive)
        print("Device alive: \(aliveStatus == noErr && isAlive != 0)")
        
        // Check supported sample rates
        address.mSelector = kAudioDevicePropertyAvailableNominalSampleRates
        address.mScope = kAudioObjectPropertyScopeGlobal
        if AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr {
            let count = Int(dataSize) / MemoryLayout<AudioValueRange>.size
            var sampleRates = Array(repeating: AudioValueRange(), count: count)
            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &sampleRates)
            if status == noErr {
                print("Supported sample rates: \(sampleRates.map { "\($0.mMinimum)-\($0.mMaximum)" })")
            }
        }
        
        print("=== End Device Debug Info ===")
    }

    func getDeviceFormat(deviceID: AudioDeviceID) -> StreamFormat? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var asbd = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &asbd)
        guard status == noErr else {
            print("Failed to get device format for device \(deviceID): \(status)")
            return nil
        }
        
        print("Device \(deviceID) native format:")
        print("  Sample rate: \(asbd.mSampleRate)")
        print("  Channels: \(asbd.mChannelsPerFrame)")
        print("  Bits per channel: \(asbd.mBitsPerChannel)")
        print("  Format flags: \(asbd.mFormatFlags)")
        print("  Bytes per frame: \(asbd.mBytesPerFrame)")
        
        return StreamFormat(asbd: asbd)
    }

    func createCompatibleFormat(for deviceID: AudioDeviceID, desiredChannels: Int) -> StreamFormat? {
        // Get device's native format first
        guard let nativeFormat = getDeviceFormat(deviceID: deviceID) else { return nil }
        
        // Create a format with the device's native sample rate but your desired channel count
        var asbd = nativeFormat.asbd
        asbd.mChannelsPerFrame = UInt32(desiredChannels)
        asbd.mBytesPerFrame = asbd.mChannelsPerFrame * asbd.mBitsPerChannel / 8
        
        return StreamFormat(asbd: asbd)
    }

    func validateDevice(uid: String) -> Bool {
        print("=== Validating device: \(uid) ===")
        
        // First, try to get device ID
        guard let deviceID = deviceID(forUID: uid) else {
            print("❌ Device ID not found for UID: \(uid)")
            return false
        }
        
        print("✅ Device ID found: \(deviceID)")
        
        // Check if device supports output by trying to get stream configuration
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        let configStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        
        if configStatus != noErr {
            print("❌ Device does not support output: \(configStatus)")
            return false
        }
        
        print("✅ Device supports output")
        
        // Check if we can get the device format
        guard getDeviceFormat(deviceID: deviceID) != nil else {
            print("❌ Cannot get device format")
            return false
        }
        
        print("✅ Device format accessible")
        
        // List all available devices to see what's actually there
        print("=== All available devices ===")
        let allDevices = allDevices()
        for device in allDevices {
            print("  - \(device.name) (UID: \(device.uid)) - Inputs: \(device.numInputs), Outputs: \(device.numOutputs)")
        }
        
        return true
    }
}
