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
    private var channelMatchFormat: StreamFormat
    private let provider: RenderProvider

    private var converter: AVAudioConverter?
    private let internalAVFormat: AVAudioFormat
    private var channelMatchAVFormat: AVAudioFormat
    private var deviceAVFormat: AVAudioFormat
    private var isRunning = false

    init(deviceID: AudioDeviceID, deviceFormat: StreamFormat, internalFormat: StreamFormat, provider: @escaping RenderProvider) throws {
        self.deviceID = deviceID
        self.deviceFormat = deviceFormat
        self.internalFormat = internalFormat
        self.provider = provider

        var internalFormatCopy = internalFormat.asbd
        guard let internalAVFormat = AVAudioFormat(streamDescription: &internalFormatCopy) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudio_ParamError), userInfo: nil)
        }
        self.internalAVFormat = internalAVFormat

        channelMatchFormat = StreamFormat.make(
            sampleRate: internalFormat.sampleRate,
            channels: UInt32(max(1, deviceFormat.channelCount))
        )
        var channelMatchCopy = channelMatchFormat.asbd
        guard let channelMatchAV = AVAudioFormat(streamDescription: &channelMatchCopy) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudio_ParamError), userInfo: nil)
        }
        channelMatchAVFormat = channelMatchAV

        var deviceFormatCopy = deviceFormat.asbd
        guard let deviceAV = AVAudioFormat(streamDescription: &deviceFormatCopy) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudio_ParamError), userInfo: nil)
        }
        deviceAVFormat = deviceAV

        try setupHardwareOutput()
        configureConverter()
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

        try updateFormats(using: deviceFormatASBD)

        var inputFormatCopy = deviceFormatASBD
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &inputFormatCopy, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), message: "Set input stream format")

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

        guard let channelBuffer = AVAudioPCMBuffer(pcmFormat: channelMatchAVFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return noErr
        }

        clear(buffer: channelBuffer)
        mapChannels(from: internalBuffer, to: channelBuffer)

        let preparedBuffer: AVAudioPCMBuffer
        if let converter {
            guard let deviceBuffer = AVAudioPCMBuffer(pcmFormat: deviceAVFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
                return noErr
            }

            clear(buffer: deviceBuffer)

            do {
                try converter.convert(to: deviceBuffer, from: channelBuffer)
            } catch {
                print("OutputSink conversion failed: \(error)")
                return noErr
            }

            preparedBuffer = deviceBuffer
        } else {
            channelBuffer.frameLength = AVAudioFrameCount(validFrames)
            preparedBuffer = channelBuffer
        }

        copy(from: preparedBuffer, to: ioBuffers)
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

    func updateFormats(using asbd: AudioStreamBasicDescription) throws {
        deviceFormat = StreamFormat(asbd: asbd)

        var deviceFormatCopy = asbd
        guard let newDeviceAV = AVAudioFormat(streamDescription: &deviceFormatCopy) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudio_ParamError), userInfo: nil)
        }
        deviceAVFormat = newDeviceAV

        channelMatchFormat = StreamFormat.make(
            sampleRate: internalFormat.sampleRate,
            channels: UInt32(max(1, deviceFormat.channelCount))
        )
        var channelMatchCopy = channelMatchFormat.asbd
        guard let newChannelMatchAV = AVAudioFormat(streamDescription: &channelMatchCopy) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudio_ParamError), userInfo: nil)
        }
        channelMatchAVFormat = newChannelMatchAV
    }

    func configureConverter() {
        let inputASBD = channelMatchFormat.asbd
        let deviceASBD = deviceFormat.asbd

        let needsConversion = inputASBD.mSampleRate != deviceASBD.mSampleRate ||
            inputASBD.mFormatID != deviceASBD.mFormatID ||
            inputASBD.mFormatFlags != deviceASBD.mFormatFlags ||
            inputASBD.mBytesPerFrame != deviceASBD.mBytesPerFrame ||
            inputASBD.mFramesPerPacket != deviceASBD.mFramesPerPacket

        if needsConversion {
            converter = AVAudioConverter(from: channelMatchAVFormat, to: deviceAVFormat)
            converter?.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            converter?.sampleRateConverterQuality = .max
        } else {
            converter = nil
        }
    }

    func mapChannels(from source: AVAudioPCMBuffer, to destination: AVAudioPCMBuffer) {
        let frames = Int(source.frameLength)
        destination.frameLength = AVAudioFrameCount(frames)

        guard frames > 0 else { return }

        let destChannels = Int(destination.format.channelCount)
        let srcChannels = Int(source.format.channelCount)

        guard let destPointer = destination.floatChannelData?.pointee else { return }
        memset(destPointer, 0, frames * destChannels * MemoryLayout<Float>.size)

        guard let sourceChannelsPointer = source.floatChannelData else { return }

        if source.format.isInterleaved {
            let src = sourceChannelsPointer.pointee
            let limit = min(srcChannels, destChannels)
            for frame in 0..<frames {
                let srcBase = frame * srcChannels
                let destBase = frame * destChannels
                for channel in 0..<limit {
                    destPointer[destBase + channel] = src[srcBase + channel]
                }
            }
        } else {
            let limit = min(srcChannels, destChannels)
            for channel in 0..<limit {
                let src = sourceChannelsPointer[channel]
                for frame in 0..<frames {
                    destPointer[frame * destChannels + channel] = src[frame]
                }
            }
        }
    }

    func check(_ status: OSStatus, message: String) throws {
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
