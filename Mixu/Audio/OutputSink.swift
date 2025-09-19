//
//  OutputSink.swift
//  Mixu
//
//  Created by Johan Lescure on 15/09/2025.
//

import AudioToolbox
import AVFoundation

// MARK: - Output sink with sample-rate conversion and fan-out support
final class OutputSink {
    typealias RenderProvider = (_ bufferList: UnsafeMutableAudioBufferListPointer, _ frameCapacity: Int) -> Int

    private var unit: AudioUnit?
    private let deviceID: AudioDeviceID
    private let internalFormat: StreamFormat
    private var deviceFormat: StreamFormat
    private let provider: RenderProvider

    private var converter: AVAudioConverter?
    private let internalAVFormat: AVAudioFormat
    private var deviceAVFormat: AVAudioFormat
    private var isRunning = false

    init(deviceID: AudioDeviceID, internalFormat: StreamFormat, provider: @escaping RenderProvider) throws {
        self.deviceID = deviceID
        self.internalFormat = internalFormat
        self.provider = provider
        self.deviceFormat = internalFormat

        var internalFormatCopy = internalFormat.asbd
        guard let internalAVFormat = AVAudioFormat(streamDescription: &internalFormatCopy) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudio_ParamError), userInfo: nil)
        }
        self.internalAVFormat = internalAVFormat
        self.deviceAVFormat = internalAVFormat

        try setupHardwareOutput()
    }

    deinit {
        stop()
        if let unit { AudioComponentInstanceDispose(unit) }
    }

    func start() {
        guard let unit, !isRunning else { return }
        let status = AudioOutputUnitStart(unit)
        if status != noErr {
            print("OutputSink start failed: \(status)")
        }
        isRunning = status == noErr
    }

    func stop() {
        guard let unit, isRunning else { return }
        let status = AudioOutputUnitStop(unit)
        if status != noErr {
            print("OutputSink stop failed: \(status)")
        }
        if status == noErr {
            isRunning = false
        }
    }
}

// MARK: - Hardware configuration
private extension OutputSink {
    func setupHardwareOutput() throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &description) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_InvalidProperty), userInfo: nil)
        }

        var newUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &newUnit), message: "AudioComponentInstanceNew")
        unit = newUnit
        guard let unit else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_Uninitialized), userInfo: nil) }

        var enableOutput: UInt32 = 1
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enableOutput, UInt32(MemoryLayout.size(ofValue: enableOutput))), message: "Enable output bus")

        var disableInput: UInt32 = 0
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disableInput, UInt32(MemoryLayout.size(ofValue: disableInput))), message: "Disable input bus")

        var device = deviceID
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout.size(ofValue: device))), message: "Bind device")

        var deviceFormatASBD = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &deviceFormatASBD, &dataSize), message: "Query device stream format")

        deviceFormat = StreamFormat(asbd: deviceFormatASBD)

        var deviceFormatCopy = deviceFormatASBD
        guard let outputFormat = AVAudioFormat(streamDescription: &deviceFormatCopy) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudio_ParamError), userInfo: nil)
        }

        deviceAVFormat = outputFormat

        let asbd = deviceFormat.asbd
        let canonical = internalFormat.asbd
        let needsConversion = asbd.mSampleRate != canonical.mSampleRate ||
            asbd.mChannelsPerFrame != canonical.mChannelsPerFrame ||
            asbd.mFormatID != canonical.mFormatID ||
            asbd.mFormatFlags != canonical.mFormatFlags ||
            asbd.mBytesPerFrame != canonical.mBytesPerFrame ||
            asbd.mFramesPerPacket != canonical.mFramesPerPacket

        if needsConversion {
            converter = AVAudioConverter(from: internalAVFormat, to: outputFormat)
            converter?.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            converter?.sampleRateConverterQuality = .max
        }

        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &deviceFormatASBD, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), message: "Set input stream format")

        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var callback = AURenderCallbackStruct(
            inputProc: { refCon, _, _, _, frameCount, ioData -> OSStatus in
                let sink = Unmanaged<OutputSink>.fromOpaque(refCon).takeUnretainedValue()
                guard let ioData else { return noErr }
                return sink.render(frameCount: frameCount, ioData: ioData)
            },
            inputProcRefCon: selfPointer
        )

        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), message: "Install render callback")
        try check(AudioUnitInitialize(unit), message: "Initialize output unit")
    }

    func render(frameCount: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard frameCount > 0 else { return noErr }

        let ioBuffers = UnsafeMutableAudioBufferListPointer(ioData)
        zero(buffers: ioBuffers)

        guard let internalBuffer = AVAudioPCMBuffer(pcmFormat: internalAVFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return noErr
        }

        clear(buffer: internalBuffer)

        let providedFrames = provider(UnsafeMutableAudioBufferListPointer(internalBuffer.mutableAudioBufferList), Int(frameCount))
        let validFrames = max(0, min(providedFrames, Int(frameCount)))
        internalBuffer.frameLength = AVAudioFrameCount(validFrames)

        guard validFrames > 0 else { return noErr }

        if let converter {
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: deviceAVFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
                return noErr
            }

            clear(buffer: outputBuffer)

            do {
                try converter.convert(to: outputBuffer, from: internalBuffer)
            } catch {
                print("OutputSink conversion failed: \(error)")
                return noErr
            }

            copy(from: outputBuffer, to: ioBuffers)
        } else {
            copy(from: internalBuffer, to: ioBuffers)
        }

        return noErr
    }

    func zero(buffers: UnsafeMutableAudioBufferListPointer) {
        for buffer in buffers {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
    }

    func clear(buffer: AVAudioPCMBuffer) {
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for audioBuffer in list {
            if let data = audioBuffer.mData {
                memset(data, 0, Int(audioBuffer.mDataByteSize))
            }
        }
    }

    func copy(from buffer: AVAudioPCMBuffer, to buffers: UnsafeMutableAudioBufferListPointer) {
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for index in 0..<min(buffers.count, sourceBuffers.count) {
            let byteCount = Int(sourceBuffers[index].mDataByteSize)
            if let dst = buffers[index].mData, let src = sourceBuffers[index].mData {
                memcpy(dst, src, byteCount)
                buffers[index].mDataByteSize = UInt32(byteCount)
            }
        }
    }

    func check(_ status: OSStatus, message: String) throws {
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
