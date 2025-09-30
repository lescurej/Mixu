//
//  OutputSink.swift
//  Mixu
//
//  Created by Johan Lescure on 15/09/2025.
//

import AudioToolbox
import AVFoundation

/// Output sink with sample-rate conversion and fan-out support
final class OutputSink {
    typealias RenderProvider = (_ bufferList: UnsafeMutableAudioBufferListPointer, _ frameCapacity: Int) -> Int

    private var unit: AudioUnit?
    private var deviceID: AudioDeviceID
    private let internalFormat: StreamFormat
    private var deviceFormat: StreamFormat
    private let provider: RenderProvider
    private let channelOffset: Int

    private var converter: AudioConverterRef?
    private let internalASBD: AudioStreamBasicDescription
    private var deviceASBD: AudioStreamBasicDescription

    private var isRunning = false
    private var isStopped = false

    init(deviceID: AudioDeviceID, deviceFormat: StreamFormat, internalFormat: StreamFormat, channelOffset: Int, provider: @escaping RenderProvider) throws {
        self.deviceID = deviceID
        self.provider = provider
        self.internalFormat = internalFormat
        self.deviceFormat = deviceFormat
        self.channelOffset = channelOffset

        // Store ASBDs directly - no AVAudioFormat needed
        self.internalASBD = internalFormat.asbd
        self.deviceASBD = deviceFormat.asbd
        
        // Set up format conversion if needed
        try setupConverter()

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

        // 1) Stop I/O first
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

        // Enable output (bus 0)
        var enableIO: UInt32 = 1
        try check(AudioUnitSetProperty(unit,
                                       kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Output,
                                       0,
                                       &enableIO,
                                       UInt32(MemoryLayout<UInt32>.size)),
                  message: "Enable output I/O")

        // Disable input (bus 1)
        var disableIO: UInt32 = 0
        try check(AudioUnitSetProperty(unit,
                                       kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Input,
                                       1,
                                       &disableIO,
                                       UInt32(MemoryLayout<UInt32>.size)),
                  message: "Disable input I/O")

        // Set the target device
        try check(AudioUnitSetProperty(unit,
                                       kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global,
                                       0,
                                       &deviceID,
                                       UInt32(MemoryLayout<AudioDeviceID>.size)),
                  message: "Set current device")

        // Fix the immutable value issue - create mutable copy
        var deviceASBDCopy = deviceASBD

        // Configure the HAL unit with the device format so we can address
        // individual hardware channels from the render callback.
        try check(AudioUnitSetProperty(unit,
                                       kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Input,
                                       0,
                                       &deviceASBDCopy,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                  message: "Set input stream format (device)")

        // Mirror the device format on the output scope to avoid implicit fan-out.
        try check(AudioUnitSetProperty(unit,
                                       kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output,
                                       0,
                                       &deviceASBDCopy,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                  message: "Set output stream format (device)")

        print("🔧 OutputSink: Configured HAL with device format - channels: \(deviceASBDCopy.mChannelsPerFrame), sampleRate: \(deviceASBDCopy.mSampleRate)")

        // Debug: Get actual format
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

        // Set up the render callback
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

        // Initialize the AudioUnit at the end
        try check(AudioUnitInitialize(unit), message: "Initialize AudioUnit")
    }

}


// MARK: - AudioUnit setup and render callback
private extension OutputSink {
    /*
    func setupHardwareOutput() throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_InvalidProperty), userInfo: nil)
        }

        var newUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &newUnit), message: "Create AudioUnit")
        guard let unit = newUnit else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_Uninitialized), userInfo: nil)
        }

        self.unit = unit

        var enableIO: UInt32 = 1
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enableIO, UInt32(MemoryLayout.size(ofValue: enableIO))), message: "Enable Output")

        var disableIO: UInt32 = 0
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disableIO, UInt32(MemoryLayout.size(ofValue: disableIO))), message: "Disable Input")

        var device = deviceID
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout.size(ofValue: device))), message: "Bind Device")
        
        var streamFormat = deviceASBD
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &streamFormat, UInt32(MemoryLayout.size(ofValue: streamFormat))), message: "Set Stream Format")
        
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &streamFormat, UInt32(MemoryLayout.size(ofValue: streamFormat))), message: "Set Stream Format")

        var shouldAlloc: UInt32 = 0
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_ShouldAllocateBuffer, kAudioUnitScope_Input, 0, &shouldAlloc, UInt32(MemoryLayout.size(ofValue: shouldAlloc))), message: "Disable buffer allocation")

        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var callback = AURenderCallbackStruct(
            inputProc: { refCon, _, _, _, frameCount, ioData in
                let sink = Unmanaged<OutputSink>.fromOpaque(refCon).takeUnretainedValue()
                guard let ioData else { return noErr }
                return sink.render(frameCount: frameCount, ioData: ioData)
            },
            inputProcRefCon: selfPointer
        )

        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout.size(ofValue: callback))), message: "Set Render Callback")

        try check(AudioUnitInitialize(unit), message: "Initialize AudioUnit")
    }
 */
    func render(frameCount: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard unit != nil else { return noErr }

        let frames = Int(frameCount)
        let bufferList = UnsafeMutableAudioBufferListPointer(ioData)

        let internalChannels = internalFormat.channelCount
        let deviceChannels = Int(deviceASBD.mChannelsPerFrame)

        // Collect audio from the provider into a temporary mono buffer so we can
        // remap it afterwards without clobbering the data the provider produced.
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

            // Route the captured audio into the device buffer using the
            // configured channel offset.
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

// MARK: - Format handling & converter
private extension OutputSink {
    func setupConverter() throws {
        let needsConversion = internalASBD.mSampleRate != deviceASBD.mSampleRate ||
                              internalASBD.mFormatID != deviceASBD.mFormatID ||
                              internalASBD.mFormatFlags != deviceASBD.mFormatFlags ||
                              internalASBD.mBytesPerFrame != deviceASBD.mBytesPerFrame ||
                              internalASBD.mFramesPerPacket != deviceASBD.mFramesPerPacket

        if needsConversion {
            var converter: AudioConverterRef?
            var sourceASBD = internalASBD  // Create mutable copy
            var destASBD = deviceASBD      // Create mutable copy
            let status = AudioConverterNew(&sourceASBD, &destASBD, &converter)
            guard status == noErr, let converter = converter else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to create AudioConverter"])
            }
            self.converter = converter
        } else {
            self.converter = nil
        }
    }

    func check(_ status: OSStatus, message: String) throws {
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
