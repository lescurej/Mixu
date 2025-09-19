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

            let audioBufferList = AudioBufferList.allocate(maximumBuffers: Int(dataSize) / MemoryLayout<AudioBuffer>.stride)
            defer { audioBufferList.deallocate() }

            let status = audioBufferList.withUnsafeMutablePointer { ptr in
                AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, ptr)
            }

            guard status == noErr else { return 0 }

            var channels = 0
            for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
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

    func streamFormat(deviceID: AudioDeviceID, scope: DeviceScope) -> StreamFormat? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: scope == .input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var asbd = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &asbd)
        guard status == noErr else {
            return nil
        }

        return StreamFormat(asbd: asbd)
    }

    func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var uidString = uid as CFString

        var translation = AudioValueTranslation(
            mInputData: nil,
            mInputDataSize: UInt32(MemoryLayout<CFString>.size),
            mOutputData: &deviceID,
            mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        var result: AudioDeviceID? = nil

        withUnsafeMutablePointer(to: &uidString) { uidPointer in
            translation.mInputData = UnsafeMutableRawPointer(uidPointer)
            var dataSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
            let status = withUnsafeMutablePointer(to: &translation) { ptr in
                AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, ptr)
            }

            if status == noErr {
                result = deviceID
            }
        }

        if let deviceID = result {
            return deviceID
        }

        return allDevices().first(where: { $0.uid == uid })?.id
    }
}
