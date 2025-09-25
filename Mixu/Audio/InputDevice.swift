//
//  InputDevice.swift
//  Mixu
//
//  Created by Johan Lescure on 15/09/2025.
//

import AudioToolbox
import AVFoundation
import Foundation

final class InputDevice {
    typealias SampleHandler = (_ buffer: UnsafePointer<Float>, _ frameCount: Int, _ channelCount: Int) -> Void

    private var unit: AudioUnit?
    private let deviceID: AudioDeviceID
    private var deviceFormat: StreamFormat
    private let internalFormat: StreamFormat
    private var normalizedFormat: StreamFormat
    private let handler: SampleHandler

    private var converter: AudioConverterRef?
    private let deviceASBD: AudioStreamBasicDescription
    private let normalizedASBD: AudioStreamBasicDescription
    private let internalASBD: AudioStreamBasicDescription

    private var isRunning = false
    private let framesPerBuffer: Int

    // MARK: - Initialization

    init(deviceID: AudioDeviceID, deviceFormat: StreamFormat, internalFormat: StreamFormat, handler: @escaping SampleHandler) throws {
        self.deviceID = deviceID
        self.deviceFormat = deviceFormat
        self.internalFormat = internalFormat
        self.handler = handler

        let validatedInternalFormat = internalFormat
        if validatedInternalFormat.sampleRate <= 0 {
            throw NSError(domain: "InputDevice", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid internal format sample rate"])
        }
        if validatedInternalFormat.channelCount <= 0 {
            throw NSError(domain: "InputDevice", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid internal format channel count"])
        }
        self.internalASBD = validatedInternalFormat.asbd

        let validatedDeviceFormat = deviceFormat
        if validatedDeviceFormat.sampleRate <= 0 {
            throw NSError(domain: "InputDevice", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid device format sample rate"])
        }
        if validatedDeviceFormat.channelCount <= 0 {
            throw NSError(domain: "InputDevice", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid device format channel count"])
        }
        self.deviceASBD = validatedDeviceFormat.asbd

        self.normalizedFormat = StreamFormat.make(
            sampleRate: validatedInternalFormat.sampleRate,
            channels: UInt32(max(1, validatedDeviceFormat.channelCount))
        )
        self.normalizedASBD = normalizedFormat.asbd

        self.framesPerBuffer = max(128, min(2048, Int(validatedInternalFormat.sampleRate / 100)))

        try setupHardwareInput()
    }

    deinit {
        stop()
        if let unit { AudioComponentInstanceDispose(unit) }
        if let converter { AudioConverterDispose(converter) }
    }

    func start() {
        guard !isRunning else { return }
        guard let unit else { return }

        print("�� InputDevice.start: Starting AudioUnit for device \(deviceID)")
        let status = AudioOutputUnitStart(unit)
        if status == noErr {
            isRunning = true
            print("✅ InputDevice.start: AudioUnit started successfully")
        } else {
            print("❌ InputDevice.start: Failed to start AudioUnit, status: \(status)")
        }
    }

    func stop() {
        guard isRunning else { return }
        guard let unit else { return }

        AudioOutputUnitStop(unit)
        isRunning = false
    }
}

// MARK: - Hardware Setup

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
            throw NSError(domain: "InputDevice", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to find AudioComponent"])
        }

        var newUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &newUnit), message: "AudioComponentInstanceNew")
        unit = newUnit
        guard let unit else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_Uninitialized), userInfo: nil)
        }

        // Enable input (bus 1) - this is what we want
        var enableIO: UInt32 = 1
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableIO, UInt32(MemoryLayout.size(ofValue: enableIO))), message: "Enable input")

        // Disable output (bus 0) - we don't want to output to the microphone
        var disableIO: UInt32 = 0
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disableIO, UInt32(MemoryLayout.size(ofValue: disableIO))), message: "Disable output")

        // Set the target device
        var device = deviceID
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout.size(ofValue: device))), message: "Bind device")

        // Set the input format (what the microphone provides)
        var deviceASBDCopy = deviceASBD
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &deviceASBDCopy, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), message: "Set Input Stream Format")

        print("✅ InputDevice: Set device input format - channels: \(deviceASBDCopy.mChannelsPerFrame)")
        
        // Request a normalized interleaved float format on the AudioUnit output bus
        var normalizedASBDCopy = normalizedASBD
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &normalizedASBDCopy, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), message: "Set normalized output stream format")

        print("✅ InputDevice: Set normalized output format - channels: \(normalizedASBDCopy.mChannelsPerFrame)")

        try setupConverter()

        var callback = AURenderCallbackStruct(
            inputProc: InputDevice.inputCallback,
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout.size(ofValue: callback))), message: "Install input callback")

        // Initialize the AudioUnit at the end
        try check(AudioUnitInitialize(unit), message: "Initialize unit")
    }

    // MARK: - Input Render Callback

    func render(frameCount: UInt32) -> OSStatus {
        guard let unit else { return noErr }
        
        let frames = Int(frameCount)
        let channelCount = normalizedFormat.channelCount
        let totalSamples = frames * channelCount
        
        guard totalSamples > 0 else { return noErr }
        
        // Create a buffer for the audio data (interleaved across all channels)
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: totalSamples)
        defer { buffer.deallocate() }
        
        // Create AudioBufferList for AudioUnitRender
        var bufferList = AudioBufferList()
        bufferList.mNumberBuffers = 1
        bufferList.mBuffers.mNumberChannels = UInt32(channelCount)
        bufferList.mBuffers.mDataByteSize = UInt32(totalSamples * MemoryLayout<Float>.size)
        bufferList.mBuffers.mData = UnsafeMutableRawPointer(buffer)
        
        // Create a timestamp for AudioUnitRender
        var timeStamp = AudioTimeStamp()
        timeStamp.mFlags = .sampleTimeValid
        timeStamp.mSampleTime = 0
        
        // Render audio from the AudioUnit
        let status = AudioUnitRender(unit, nil, &timeStamp, 1, frameCount, &bufferList)
        
        if status != noErr {
            print("❌ InputDevice.render: AudioUnitRender failed with status: \(status)")
            return status
        }
        
        // Call the sample handler with the captured audio data
        handler(buffer, frames, channelCount)
        
        return noErr
    }

    func mapChannelsAndCallHandler(_ buffer: UnsafePointer<Float>, frames: Int) {
        let internalChannels = internalFormat.channelCount
        let deviceChannels = deviceFormat.channelCount

        let internalBuffer = UnsafeMutablePointer<Float>.allocate(capacity: frames * internalChannels)
        defer { internalBuffer.deallocate() }

        memset(internalBuffer, 0, frames * internalChannels * MemoryLayout<Float>.size)

        if deviceFormat.isInterleaved {
            for frame in 0..<frames {
                let sourceIndex = frame * deviceChannels
                let targetIndex = frame * internalChannels
                
                for channel in 0..<min(deviceChannels, internalChannels) {
                    internalBuffer[targetIndex + channel] = buffer[sourceIndex + channel]
                }
            }
        } else {
            for channel in 0..<min(deviceChannels, internalChannels) {
                let sourceOffset = channel * frames
                let targetOffset = channel * frames
                
                for frame in 0..<frames {
                    internalBuffer[targetOffset + frame] = buffer[sourceOffset + frame]
                }
            }
        }

        handler(UnsafePointer(internalBuffer), frames, internalChannels)
    }

    static let inputCallback: AURenderCallback = { refCon, _, _, _, frameCount, _ in
        let instance = Unmanaged<InputDevice>.fromOpaque(refCon).takeUnretainedValue()
        return instance.render(frameCount: frameCount)
    }

    static let converterFillerCallback: AudioConverterComplexInputDataProc = { _, ioNumberDataPackets, ioData, _, inUserData in
        guard let inUserData else { return kAudio_ParamError }

        let inputBufferList = inUserData.assumingMemoryBound(to: AudioBufferList.self)
        ioData.pointee = inputBufferList.pointee
        return noErr
    }

    func setupConverter() throws {
        let needsConversion = deviceASBD.mSampleRate != normalizedASBD.mSampleRate ||
            deviceASBD.mFormatID != normalizedASBD.mFormatID ||
            deviceASBD.mFormatFlags != normalizedASBD.mFormatFlags ||
            deviceASBD.mBytesPerFrame != normalizedASBD.mBytesPerFrame ||
            deviceASBD.mFramesPerPacket != normalizedASBD.mFramesPerPacket

        if needsConversion {
            var source = deviceASBD
            var dest = normalizedASBD
            var newConverter: AudioConverterRef?

            let status = AudioConverterNew(&source, &dest, &newConverter)
            if status != noErr || newConverter == nil {
                throw NSError(domain: "InputDevice", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to create AudioConverter"])
            }

            self.converter = newConverter
            print("Created AudioConverter for input format conversion")
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
