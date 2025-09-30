//
//  OutputSink.swift
//  Mixu
//
//  Created by Johan Lescure on 15/09/2025.
//

import AudioToolbox

/// Output sink with sample-rate conversion and fan-out support
final class OutputSink {
    typealias RenderProvider = (_ bufferList: UnsafeMutableAudioBufferListPointer, _ frameCapacity: Int) -> Int

    private var unit: AudioUnit?
    private var deviceID: AudioDeviceID
    private let internalFormat: StreamFormat
    private let provider: RenderProvider
    private let channelOffset: Int

    private var deviceASBD: AudioStreamBasicDescription

    private var isRunning = false
    private var isStopped = false

    init(deviceID: AudioDeviceID, deviceFormat: StreamFormat, internalFormat: StreamFormat, channelOffset: Int, provider: @escaping RenderProvider) throws {
        self.deviceID = deviceID
        self.provider = provider
        self.internalFormat = internalFormat
        self.channelOffset = channelOffset

        self.deviceASBD = deviceFormat.asbd

        try setupAudioUnit()
    }

    deinit {
        guard let unit, !isStopped else { return }
        stop()

        let disposeStatus = AudioComponentInstanceDispose(unit)
        if disposeStatus == noErr {
            print("✅ AudioUnit disposed")
        } else {
            print("⚠️ Dispose failed: \(disposeStatus)")
        }

        self.unit = nil
        isRunning = false
    }

    func start() {
        guard !isRunning else { return }
        guard let unit else { return }

        let status = AudioOutputUnitStart(unit)
        if status == noErr {
            isRunning = true
        }
    }

    func stop() {
        guard let unit, !isStopped else { return }
        print("⏹️ OutputSink.stop: Stopping AudioUnit")

        let stopStatus = AudioOutputUnitStop(unit)
        if stopStatus == noErr {
            print("✅ AudioOutputUnitStop succeeded")
        } else {
            return
        }
        isStopped = true
    }

    private func setupAudioUnit() throws {
        var componentDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &componentDescription) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: -1, userInfo: [NSLocalizedDescriptionKey: "AudioComponent not found"])
        }

        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let unit = unit else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to create AudioUnit instance"])
        }

        var enableIO: UInt32 = 1
        try check(AudioUnitSetProperty(unit,
                                       kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Output,
                                       0,
                                       &enableIO,
                                       UInt32(MemoryLayout<UInt32>.size)),
                  message: "Enable output I/O")

        var disableIO: UInt32 = 0
        try check(AudioUnitSetProperty(unit,
                                       kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Input,
                                       1,
                                       &disableIO,
                                       UInt32(MemoryLayout<UInt32>.size)),
                  message: "Disable input I/O")

        try check(AudioUnitSetProperty(unit,
                                       kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global,
                                       0,
                                       &deviceID,
                                       UInt32(MemoryLayout<AudioDeviceID>.size)),
                  message: "Set current device")

        var deviceASBDCopy = deviceASBD

        try check(AudioUnitSetProperty(unit,
                                       kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Input,
                                       0,
                                       &deviceASBDCopy,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                  message: "Set input stream format (device)")

        try check(AudioUnitSetProperty(unit,
                                       kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output,
                                       0,
                                       &deviceASBDCopy,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                  message: "Set output stream format (device)")

        print("🔧 OutputSink: Configured HAL with device format - channels: \(deviceASBDCopy.mChannelsPerFrame), sampleRate: \(deviceASBDCopy.mSampleRate)")

        var actualASBD = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(unit,
                                      kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Input,
                                      0,
                                      &actualASBD,
                                      &size)

        if status == noErr {
            deviceASBD = actualASBD
            print("✅ AudioUnit accepted device format:", actualASBD)
        } else {
            print("❌ Failed to get input stream format: OSStatus =", status)
        }

        var callback = AURenderCallbackStruct(
            inputProc: { (refCon, _, _, _, frameCount, ioData) -> OSStatus in
                guard let ioData = ioData else {
                    print("⚠️ ioData is nil")
                    return noErr
                }

                let sink = Unmanaged<OutputSink>.fromOpaque(refCon).takeUnretainedValue()
                return sink.render(frameCount: frameCount, ioData: ioData)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        try check(AudioUnitSetProperty(unit,
                                       kAudioUnitProperty_SetRenderCallback,
                                       kAudioUnitScope_Input,
                                       0,
                                       &callback,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                  message: "Set render callback")

        try check(AudioUnitInitialize(unit), message: "Initialize AudioUnit")
    }

}


// MARK: - AudioUnit setup and render callback
private extension OutputSink {
    func render(frameCount: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard unit != nil else { return noErr }

        let frames = Int(frameCount)
        let bufferList = UnsafeMutableAudioBufferListPointer(ioData)

        let internalChannels = internalFormat.channelCount
        let deviceChannels = Int(deviceASBD.mChannelsPerFrame)

        var framesProvided = 0
        let bytesPerInternalFrame = internalChannels * MemoryLayout<Float>.size
        var scratch = Array<Float>(repeating: 0, count: frames * internalChannels)

        scratch.withUnsafeMutableBytes { rawBuffer in
            guard let scratchPtr = rawBuffer.bindMemory(to: Float.self).baseAddress else {
                return
            }

            let audioBuffer = AudioBuffer(
                mNumberChannels: UInt32(internalChannels),
                mDataByteSize: UInt32(frames * bytesPerInternalFrame),
                mData: scratchPtr
            )

            var monoList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: audioBuffer
            )

            framesProvided = provider(UnsafeMutableAudioBufferListPointer(&monoList), frames)

            guard framesProvided > 0 else { return }

            if bufferList.count == 1 {
                guard let dest = bufferList[0].mData?.assumingMemoryBound(to: Float.self) else {
                    framesProvided = 0
                    return
                }

                memset(dest, 0, frames * deviceChannels * MemoryLayout<Float>.size)

                for frameIndex in 0..<framesProvided {
                    for channel in 0..<internalChannels {
                        let sourceValue = scratchPtr[frameIndex * internalChannels + channel]
                        let targetChannel = channelOffset + channel
                        if targetChannel < deviceChannels {
                            dest[frameIndex * deviceChannels + targetChannel] = sourceValue
                        }
                    }
                }

                bufferList[0].mDataByteSize = UInt32(framesProvided * deviceChannels * MemoryLayout<Float>.size)
            } else {
                for channel in 0..<min(internalChannels, bufferList.count) {
                    let targetChannel = channelOffset + channel
                    guard targetChannel < bufferList.count,
                          let dest = bufferList[targetChannel].mData?.assumingMemoryBound(to: Float.self) else {
                        continue
                    }

                    memset(dest, 0, frames * MemoryLayout<Float>.size)

                    for frameIndex in 0..<framesProvided {
                        let sourceValue = scratchPtr[frameIndex * internalChannels + channel]
                        dest[frameIndex] = sourceValue
                    }

                    bufferList[targetChannel].mDataByteSize = UInt32(framesProvided * MemoryLayout<Float>.size)
                }
            }
        }

        return noErr
    }
}

// MARK: - Format handling
private extension OutputSink {
    func check(_ status: OSStatus, message: String) throws {
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
