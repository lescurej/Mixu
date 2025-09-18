//
//  AudioDeviceManager.swift
//  Mixu
//
//  Created by Johan Lescure on 15/09/2025.
//

import CoreAudio

// MARK: - AudioDevice Query Helpers
struct AudioDevice {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let numOutputs: Int
    let numInputs: Int
}

enum DeviceScope { case input, output }

final class AudioDeviceManager {
    func allDevices() -> [AudioDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }
        return deviceIDs.compactMap { deviceInfo(deviceID: $0) }
    }

    func deviceInfo(deviceID: AudioDeviceID) -> AudioDevice? {
        func stringProp(_ selector: AudioObjectPropertySelector) -> String? {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var dataSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &dataSize) == noErr else {
                return nil
            }

            // Allouer un buffer pour recevoir le CFString
            var cfStr: CFString? = nil
            let status = withUnsafeMutablePointer(to: &cfStr) { ptr -> OSStatus in
                return AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &dataSize, ptr)
            }
            guard status == noErr, let value = cfStr else { return nil }

            return value as String
        }
        func numStreams(_ scope: DeviceScope) -> Int {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: (scope == .input) ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr else { return 0 }
            
            let audioBufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
            defer { audioBufferList.deallocate() }
            
            guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, audioBufferList) == noErr else { return 0 }
            
            var channelCount = 0
            let bufferList = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in bufferList {
                channelCount += Int(buffer.mNumberChannels)
            }
            
            return channelCount
        }
        guard let name = stringProp(kAudioObjectPropertyName), let uid = stringProp(kAudioDevicePropertyDeviceUID) else { return nil }
        let numOutputs = numStreams(.output)
        let numInputs = numStreams(.input)
        return AudioDevice(id: deviceID, name: name, uid: uid, numOutputs: numOutputs, numInputs: numInputs)
    }

    func findDevice(byName name: String) -> AudioDevice? {
        allDevices().first { $0.name.contains(name) }
    }
    
    func deviceID(forUID uid: String) -> AudioDeviceID? {
        // Direct approach: just search through all devices
        // This is more reliable than the Core Audio UID lookup API
        if let device = allDevices().first(where: { $0.uid == uid }) {
            print("✅ Found device directly: \(device.name) (ID: \(device.id))")
            return device.id
        }
        
        print("❌ Device not found for UID: \(uid)")
        return nil
    }
}

