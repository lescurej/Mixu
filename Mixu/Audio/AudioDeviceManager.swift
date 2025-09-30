//
//  AudioDeviceManager.swift
//  Mixu
//
//  Created by Johan Lescure on 15/09/2025.
//

import AudioToolbox
import CoreAudio

// MARK: - AudioDevice Query Helpers
struct AudioDevice: Hashable, Identifiable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let numOutputs: Int
    let numInputs: Int
    
    // MARK: - Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    // MARK: - Equatable conformance
    static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
        return lhs.id == rhs.id
    }
}

enum DeviceScope {
    case input
    case output
}

final class AudioDeviceManager {
    private var deviceChangeListeners: [AudioDeviceID: AudioObjectPropertyListenerProc] = [:]
    private var listenerContexts: [AudioDeviceID: UnsafeMutableRawPointer] = [:]
    private var connectedDeviceIDs: Set<AudioDeviceID> = []
    
    init() {
        // Don't set up listeners in init - wait for devices to be connected
    }
    
    deinit {
        removeAllDeviceChangeListeners()
    }
    
    func addDeviceChangeListener(for deviceID: AudioDeviceID) {
        // Only add listener if not already listening
        guard !connectedDeviceIDs.contains(deviceID) else { return }
        
        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        listenerContexts[deviceID] = selfPointer
        
        let listener: AudioObjectPropertyListenerProc = { (objectID, numAddresses, addresses, clientData) -> OSStatus in
            guard let clientData = clientData else { return noErr }
            let manager = Unmanaged<AudioDeviceManager>.fromOpaque(clientData).takeUnretainedValue()
            return manager.handleDevicePropertyChange(objectID: objectID, addresses: addresses, numAddresses: numAddresses)
        }
        
        deviceChangeListeners[deviceID] = listener
        
        // Listen for stream format changes on this specific device
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectAddPropertyListener(
            deviceID,
            &address,
            listener,
            selfPointer
        )
        
        if status != noErr {
            print("Failed to add device property listener for device \(deviceID): \(status)")
            deviceChangeListeners.removeValue(forKey: deviceID)
            listenerContexts.removeValue(forKey: deviceID)
        } else {
            connectedDeviceIDs.insert(deviceID)
            print("Added format change listener for device \(deviceID)")
        }
    }
    
    func removeDeviceChangeListener(for deviceID: AudioDeviceID) {
        guard let listener = deviceChangeListeners[deviceID],
              let context = listenerContexts[deviceID] else { return }
        
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        AudioObjectRemovePropertyListener(
            deviceID,
            &address,
            listener,
            context
        )
        
        deviceChangeListeners.removeValue(forKey: deviceID)
        listenerContexts.removeValue(forKey: deviceID)
        connectedDeviceIDs.remove(deviceID)
        
        print("Removed format change listener for device \(deviceID)")
    }
    
    private func removeAllDeviceChangeListeners() {
        for deviceID in connectedDeviceIDs {
            removeDeviceChangeListener(for: deviceID)
        }
    }
    
    private func handleDevicePropertyChange(objectID: AudioObjectID, addresses: UnsafePointer<AudioObjectPropertyAddress>, numAddresses: UInt32) -> OSStatus {
        // Only process if this is a connected device
        guard connectedDeviceIDs.contains(objectID) else { return noErr }
        
        // Check if this is a device format change
        for i in 0..<Int(numAddresses) {
            let address = addresses[i]
            if address.mSelector == kAudioDevicePropertyStreamFormat {
                // Notify that a device format has changed
                NotificationCenter.default.post(
                    name: .audioDeviceFormatChanged,
                    object: nil,
                    userInfo: ["deviceID": objectID]
                )
                print("Format change detected for connected device \(objectID)")
            }
        }
        
        return noErr
    }

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

            var totalChannels = 0
            var propertyDataSize = dataSize

            var bufferStorage = [UInt8](repeating: 0, count: Int(dataSize))
            let status = bufferStorage.withUnsafeMutableBytes { rawBuffer -> OSStatus in
                guard let baseAddress = rawBuffer.baseAddress else {
                    return kAudio_ParamError
                }

                let listPointer = baseAddress.assumingMemoryBound(to: AudioBufferList.self)
                let fetchStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertyDataSize, listPointer)
                guard fetchStatus == noErr else {
                    return fetchStatus
                }

                let buffers = UnsafeMutableAudioBufferListPointer(listPointer)
                for buffer in buffers {
                    totalChannels += Int(buffer.mNumberChannels)
                }
                return noErr
            }

            guard status == noErr else { return 0 }
            return totalChannels
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
        guard status == noErr else { return nil }

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

        let found = withUnsafeMutablePointer(to: &uidString) { uidPointer -> Bool in
            withUnsafeMutablePointer(to: &deviceID) { devicePointer -> Bool in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(uidPointer),
                    mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                    mOutputData: UnsafeMutableRawPointer(devicePointer),
                    mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
                )

                var propertyDataSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
                let status = withUnsafeMutablePointer(to: &translation) { translationPointer in
                    AudioObjectGetPropertyData(
                        AudioObjectID(kAudioObjectSystemObject),
                        &address,
                        0,
                        nil,
                        &propertyDataSize,
                        translationPointer
                    )
                }

                return status == noErr
            }
        }

        if found {
            return deviceID
        }

        return allDevices().first(where: { $0.uid == uid })?.id
    }
}

extension Notification.Name {
    static let audioDeviceFormatChanged = Notification.Name("audioDeviceFormatChanged")
}
