//
//  AudioPlugin.swift
//  Mixu
//
//  Created by Johan Lescure on 17/09/2025.
//

import AudioToolbox
import Foundation

// MARK: - Descriptors
struct AudioPluginDescriptor: Identifiable, Hashable {
    enum Kind {
        case audioUnit(AudioComponentDescription)
        case vst3(URL)
    }

    let id: UUID
    let name: String
    let kind: Kind

    init(id: UUID = UUID(), name: String, audioUnitDescription: AudioComponentDescription) {
        self.id = id
        self.name = name
        self.kind = .audioUnit(audioUnitDescription)
    }

    init(id: UUID = UUID(), name: String, vst3URL: URL) {
        self.id = id
        self.name = name
        self.kind = .vst3(vst3URL)
    }

    static func audioUnit(name: String, type: OSType, subtype: OSType, manufacturer: OSType) -> AudioPluginDescriptor {
        let description = AudioComponentDescription(
            componentType: type,
            componentSubType: subtype,
            componentManufacturer: manufacturer,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        return AudioPluginDescriptor(name: name, audioUnitDescription: description)
    }

    func audioUnitDescription() -> AudioComponentDescription? {
        if case let .audioUnit(description) = kind { return description }
        return nil
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AudioPluginDescriptor, rhs: AudioPluginDescriptor) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Effect Chain
final class AudioEffectChain {
    private let format: StreamFormat
    private var effects: [AudioUnitEffect] = []

    init(descriptors: [AudioPluginDescriptor], format: StreamFormat) {
        self.format = format

        for descriptor in descriptors {
            switch descriptor.kind {
            case let .audioUnit(description):
                do {
                    let effect = try AudioUnitEffect(componentDescription: description, format: format)
                    effects.append(effect)
                } catch {
                    print("❌ AudioEffectChain: Failed to load Audio Unit \(descriptor.name): \(error)")
                }
            case let .vst3(url):
                print("⚠️ AudioEffectChain: VST3 plugins are not yet supported (requested: \(url.path))")
            }
        }
    }

    var isEmpty: Bool { effects.isEmpty }

    func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        guard !effects.isEmpty else { return }

        for effect in effects {
            effect.process(buffer: buffer, frameCount: frameCount)
        }
    }
}

// MARK: - Audio Unit Wrapper
private final class AudioUnitEffect {
    private var unit: AudioUnit?
    private let channels: UInt32

    init(componentDescription: AudioComponentDescription, format: StreamFormat) throws {
        var description = componentDescription

        guard let component = AudioComponentFindNext(nil, &description) else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(kAudioUnitErr_InvalidElement),
                userInfo: [NSLocalizedDescriptionKey: "Audio component not found"]
            )
        }

        var newUnit: AudioUnit?
        let status = AudioComponentInstanceNew(component, &newUnit)
        guard status == noErr, let unit = newUnit else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Failed to instantiate Audio Unit"]
            )
        }

        self.unit = unit
        self.channels = UInt32(format.channelCount)

        do {
            var streamFormat = format.asbd
            try AudioUnitEffect.check(AudioUnitSetProperty(unit,
                                                           kAudioUnitProperty_StreamFormat,
                                                           kAudioUnitScope_Input,
                                                           0,
                                                           &streamFormat,
                                                           UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
        } catch {
            print("❌ AudioEffectChain: Failed to load Audio Unit: \(error)")

        }
       
        do {
            var outputFormat = format.asbd
            try AudioUnitEffect.check(AudioUnitSetProperty(unit,
                                                           kAudioUnitProperty_StreamFormat,
                                                           kAudioUnitScope_Output,
                                                           0,
                                                           &outputFormat,
                                                           UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
        } catch {
            print("❌ AudioEffectChain: Failed to load Audio Unit: \(error)")

        }
        
        do {
            var maxFrames: UInt32 = 4096
            _ = AudioUnitSetProperty(unit,
                                     kAudioUnitProperty_MaximumFramesPerSlice,
                                     kAudioUnitScope_Global,
                                     0,
                                     &maxFrames,
                                     UInt32(MemoryLayout<UInt32>.size))

            try AudioUnitEffect.check(AudioUnitInitialize(unit))
        } catch {
            print("❌ AudioEffectChain: Failed to load Audio Unit: \(error)")

        }
    }

    deinit {
        if let unit {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
    }

    func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard let unit else { return }
        guard frameCount > 0 else { return }

        var actionFlags: AudioUnitRenderActionFlags = []
        let audioBuffer = AudioBuffer(
            mNumberChannels: channels,
            mDataByteSize: UInt32(frameCount * Int(channels) * MemoryLayout<Float>.size),
            mData: buffer
        )
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: audioBuffer
        )

        // Create a timestamp for AudioUnitProcess
        var timeStamp = AudioTimeStamp()
        timeStamp.mFlags = .sampleTimeValid
        timeStamp.mSampleTime = 0

        let status = AudioUnitProcess(unit, &actionFlags, &timeStamp, UInt32(frameCount), &bufferList)
        if status != noErr {
            print("❌ AudioUnitEffect: Processing failed with status \(status)")
        }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: nil
            )
        }
    }
}
