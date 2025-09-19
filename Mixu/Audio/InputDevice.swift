//
//  InputDevice.swift
//  Mixu
//
//  Created by Johan Lescure on 15/09/2025.
//

import AudioToolbox
import AVFoundation
import Foundation

// MARK: - Input Device (Real device or synthetic test tone)
final class InputDevice {
    typealias SampleHandler = (_ buffer: UnsafePointer<Float>, _ frameCount: Int) -> Void

    private var unit: AudioUnit?
    private let deviceID: AudioDeviceID
    private var deviceFormat: StreamFormat
    private let internalFormat: StreamFormat
    private var normalizedFormat: StreamFormat
    private let handler: SampleHandler

    private var converter: AVAudioConverter?
    private var deviceAVFormat: AVAudioFormat
    private var normalizedAVFormat: AVAudioFormat
    private let internalAVFormat: AVAudioFormat

    private var timer: Timer?
    private var sampleCount: Int = 0
    private var isRunning = false
    private let useTestTone: Bool

    // Test tone constants
    private let frequency = 440.0
    private let amplitude = 0.25
    private let framesPerBuffer: Int

    init(deviceID: AudioDeviceID, deviceFormat: StreamFormat, internalFormat: StreamFormat, useTestTone: Bool = false, handler: @escaping SampleHandler) throws {
        self.deviceID = deviceID
        self.deviceFormat = deviceFormat
        self.internalFormat = internalFormat
        self.handler = handler
        self.useTestTone = useTestTone || deviceID == 0

        var internalFormatCopy = internalFormat.asbd
        guard let internalAV = AVAudioFormat(streamDescription: &internalFormatCopy) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudio_ParamError), userInfo: nil)
        }
        internalAVFormat = internalAV

        normalizedFormat = StreamFormat.make(
            sampleRate: internalFormat.sampleRate,
            channels: UInt32(max(1, deviceFormat.channelCount))
        )
        var normalizedCopy = normalizedFormat.asbd
        guard let normalizedAV = AVAudioFormat(streamDescription: &normalizedCopy) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudio_ParamError), userInfo: nil)
        }
        normalizedAVFormat = normalizedAV

        var deviceFormatCopy = deviceFormat.asbd
        guard let deviceAV = AVAudioFormat(streamDescription: &deviceFormatCopy) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudio_ParamError), userInfo: nil)
        }
        deviceAVFormat = deviceAV

        framesPerBuffer = max(128, min(2048, Int(internalFormat.sampleRate / 100)))

        if self.useTestTone {
            setupTestTone()
        } else {
            try setupHardwareInput()
        }
    }

    deinit {
        stop()
        if let unit { AudioComponentInstanceDispose(unit) }
    }

    func start() {
        guard !isRunning else { return }

        if useTestTone {
            isRunning = true
            primeTestTone()
            timer = Timer.scheduledTimer(withTimeInterval: Double(framesPerBuffer) / max(1.0, internalFormat.sampleRate), repeats: true) { [weak self] _ in
                self?.generateTestTone()
            }
        } else if let unit {
            let status = AudioOutputUnitStart(unit)
            if status != noErr {
                print("InputDevice start failed: \(status)")
                isRunning = false
            } else {
                isRunning = true
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        if useTestTone {
            timer?.invalidate()
            timer = nil
        } else if let unit {
            let status = AudioOutputUnitStop(unit)
            if status != noErr {
                print("InputDevice stop failed: \(status)")
            }
        }
    }
}

// MARK: - Test tone helpers
private extension InputDevice {
    func setupTestTone() {
        // Nothing to configure in advance, tone will be generated in software.
    }

    func primeTestTone() {
        for _ in 0..<4 {
            generateTestTone()
        }
    }

    func generateTestTone() {
        guard isRunning else { return }

        let channels = Int(internalFormat.asbd.mChannelsPerFrame)
        let sampleRate = max(1.0, internalFormat.sampleRate)
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: framesPerBuffer * channels)
        defer { buffer.deallocate() }

        for frame in 0..<framesPerBuffer {
            let time = Double(sampleCount + frame) / sampleRate
            let value = Float(amplitude * sin(2.0 * .pi * frequency * time))

            for channel in 0..<channels {
                buffer[frame * channels + channel] = value
            }
        }

        sampleCount += framesPerBuffer
        handler(buffer, framesPerBuffer)
    }
}

// MARK: - Hardware configuration
private extension InputDevice {
    func setupHardwareInput() throws {
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

        var enableIO: UInt32 = 1
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableIO, UInt32(MemoryLayout.size(ofValue: enableIO))), message: "Enable input bus")

        var disableIO: UInt32 = 0
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disableIO, UInt32(MemoryLayout.size(ofValue: disableIO))), message: "Disable output bus")

        var device = deviceID
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout.size(ofValue: device))), message: "Bind device")

        var desiredFormat = deviceFormat.asbd
        desiredFormat.mFormatID = kAudioFormatLinearPCM
        desiredFormat.mFormatFlags = kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked
        desiredFormat.mBitsPerChannel = 32
        desiredFormat.mBytesPerFrame = UInt32(4 * Int(desiredFormat.mChannelsPerFrame))
        desiredFormat.mFramesPerPacket = 1
        desiredFormat.mBytesPerPacket = desiredFormat.mBytesPerFrame

        let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let setStatus = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &desiredFormat, size)

        var appliedFormat = desiredFormat
        if setStatus != noErr {
            var actualFormat = AudioStreamBasicDescription()
            var actualSize = size
            try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &actualFormat, &actualSize), message: "Query device stream format")
            appliedFormat = actualFormat
        }

        try updateDeviceFormat(using: appliedFormat)

        configureConverter()

        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var callback = AURenderCallbackStruct(
            inputProc: { refCon, _, _, _, frameCount, _ -> OSStatus in
                let input = Unmanaged<InputDevice>.fromOpaque(refCon).takeUnretainedValue()
                return input.render(frameCount: frameCount)
            },
            inputProcRefCon: selfPointer
        )

        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), message: "Install input callback")
        try check(AudioUnitInitialize(unit), message: "Initialize input unit")
    }

    func render(frameCount: UInt32) -> OSStatus {
        guard let unit else { return noErr }

        let frames = Int(frameCount)
        guard frames > 0 else { return noErr }

        guard let deviceBuffer = AVAudioPCMBuffer(pcmFormat: deviceAVFormat, frameCapacity: frameCount) else {
            return noErr
        }

        var audioBufferList = deviceBuffer.mutableAudioBufferList
        var flags: AudioUnitRenderActionFlags = []
        var timeStamp = AudioTimeStamp()
        timeStamp.mFlags = [.sampleTimeValid, .hostTimeValid]

        let status = AudioUnitRender(unit, &flags, &timeStamp, 1, frameCount, audioBufferList.unsafeMutablePointer)

        guard status == noErr else {
            return status
        }

        deviceBuffer.frameLength = frameCount

        let workingBuffer: AVAudioPCMBuffer
        if let converter {
            guard let normalizedBuffer = AVAudioPCMBuffer(pcmFormat: normalizedAVFormat, frameCapacity: frameCount) else {
                return noErr
            }

            do {
                try converter.convert(to: normalizedBuffer, from: deviceBuffer)
            } catch {
                print("InputDevice conversion failed: \(error)")
                return noErr
            }

            workingBuffer = normalizedBuffer
        } else {
            workingBuffer = deviceBuffer
        }

        guard let internalBuffer = AVAudioPCMBuffer(pcmFormat: internalAVFormat, frameCapacity: frameCount) else {
            return noErr
        }

        mapChannels(from: workingBuffer, to: internalBuffer)

        let producedFrames = Int(internalBuffer.frameLength)
        guard producedFrames > 0, let data = internalBuffer.floatChannelData?.pointee else {
            return noErr
        }

        handler(UnsafePointer(data), producedFrames)
        return noErr
    }

    func updateDeviceFormat(using asbd: AudioStreamBasicDescription) throws {
        deviceFormat = StreamFormat(asbd: asbd)

        var deviceFormatCopy = asbd
        guard let newDeviceAV = AVAudioFormat(streamDescription: &deviceFormatCopy) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudio_ParamError), userInfo: nil)
        }
        deviceAVFormat = newDeviceAV

        normalizedFormat = StreamFormat.make(
            sampleRate: internalFormat.sampleRate,
            channels: UInt32(max(1, deviceFormat.channelCount))
        )
        var normalizedCopy = normalizedFormat.asbd
        guard let newNormalizedAV = AVAudioFormat(streamDescription: &normalizedCopy) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudio_ParamError), userInfo: nil)
        }
        normalizedAVFormat = newNormalizedAV
    }

    func configureConverter() {
        let deviceASBD = deviceFormat.asbd
        let normalizedASBD = normalizedFormat.asbd

        let needsConversion = deviceASBD.mSampleRate != normalizedASBD.mSampleRate ||
            deviceASBD.mFormatID != normalizedASBD.mFormatID ||
            deviceASBD.mFormatFlags != normalizedASBD.mFormatFlags ||
            deviceASBD.mBytesPerFrame != normalizedASBD.mBytesPerFrame ||
            deviceASBD.mFramesPerPacket != normalizedASBD.mFramesPerPacket

        if needsConversion {
            converter = AVAudioConverter(from: deviceAVFormat, to: normalizedAVFormat)
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
