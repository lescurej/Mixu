//
//  InputDevice.swift
//  Mixu
//
//  Created by Johan Lescure on 15/09/2025.
//

import AudioToolbox
import AVFoundation

// MARK: - Input Device (Real device or synthetic test tone)
final class InputDevice {
    typealias SampleHandler = (_ buffer: UnsafePointer<Float>, _ frameCount: Int) -> Void

    private var unit: AudioUnit?
    private let deviceID: AudioDeviceID
    private var format: StreamFormat
    private let handler: SampleHandler

    private var timer: Timer?
    private var sampleCount: Int = 0
    private var isRunning = false
    private let useTestTone: Bool

    // Test tone constants
    private let sampleRate = 48000
    private let frequency = 440.0
    private let amplitude = 0.25
    private let framesPerBuffer = 512

    init(deviceID: AudioDeviceID, format: StreamFormat, useTestTone: Bool = false, handler: @escaping SampleHandler) throws {
        self.deviceID = deviceID
        self.format = format
        self.handler = handler
        self.useTestTone = useTestTone || deviceID == 0

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
            timer = Timer.scheduledTimer(withTimeInterval: Double(framesPerBuffer) / Double(sampleRate), repeats: true) { [weak self] _ in
                self?.generateTestTone()
            }
        } else if let unit {
            let status = AudioOutputUnitStart(unit)
            if status != noErr {
                print("InputDevice start failed: \(status)")
                isRunning = false
            }
            if status == noErr { isRunning = true }
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

        let channels = Int(format.asbd.mChannelsPerFrame)
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: framesPerBuffer * channels)
        defer { buffer.deallocate() }

        for frame in 0..<framesPerBuffer {
            let time = Double(sampleCount + frame) / Double(sampleRate)
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

        var streamFormat = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &streamFormat, &dataSize), message: "Query device stream format")

        streamFormat.mFormatFlags &= ~kAudioFormatFlagIsNonInterleaved
        streamFormat.mBytesPerFrame = UInt32(4 * Int(streamFormat.mChannelsPerFrame))
        streamFormat.mBytesPerPacket = streamFormat.mBytesPerFrame
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &streamFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), message: "Set canonical stream format")

        format = StreamFormat(asbd: streamFormat)

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

        let channels = Int(format.asbd.mChannelsPerFrame)
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: Int(frameCount) * channels)
        defer { buffer.deallocate() }

        var audioBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: frameCount * UInt32(channels) * UInt32(MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(buffer)
            )
        )

        var flags: AudioUnitRenderActionFlags = []
        var timeStamp = AudioTimeStamp()
        timeStamp.mFlags = [.sampleTimeValid, .hostTimeValid]

        let status = withUnsafeMutablePointer(to: &audioBufferList) { listPtr in
            AudioUnitRender(unit, &flags, &timeStamp, 1, frameCount, listPtr)
        }

        guard status == noErr else {
            return status
        }

        handler(buffer, Int(frameCount))
        return noErr
    }

    func check(_ status: OSStatus, message: String) throws {
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
