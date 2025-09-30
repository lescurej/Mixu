//
//  InputDevice.swift
//  Mixu
//
//  Created by Johan Lescure on 15/09/2025.
//

import AudioToolbox

// MARK: - Input Device (Real or Test Tone)
final class InputDevice {
    typealias SampleHandler = (_ buffer: UnsafePointer<Float>, _ frames: Int, _ channelCount: Int) -> Void

    private var unit: AudioUnit?
    private var timer: Timer?
    private let deviceID: AudioDeviceID
    private var hardwareFormat: StreamFormat
    private var internalFormat: StreamFormat
    private let handler: SampleHandler
    private var sampleCount: Int = 0
    private var isRunning = false
    private var isTestTone = false
    private var callCount: Int = 0
    
    // Constants for test tone generation
    private let frequency = 440.0 // A4 note
    private let amplitude = 0.3
    private let framesPerBuffer = 512
    private let bufferCount = 3  // Number of buffers to keep filled
    
    init(deviceID: AudioDeviceID, deviceFormat: StreamFormat, internalFormat: StreamFormat, handler: @escaping SampleHandler) throws {
        self.deviceID = deviceID
        self.hardwareFormat = deviceFormat
        self.internalFormat = internalFormat
        self.handler = handler
        
        // Determine if we should use test tone based on device ID
        isTestTone = (deviceID == 0)
        
        if isTestTone {
            setupTestTone()
        } else {
            try setupRealDevice()
        }
    }
    
    private func setupTestTone() {
        print("🎤 Setting up test tone generator (440 Hz sine wave)")
    }
    
    private func setupRealDevice() throws {
        print("🎤 Setting up real device input with device ID: \(deviceID)")
        
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw NSError(domain: "HAL", code: -1) }
        var u: AudioUnit?
        let status1 = AudioComponentInstanceNew(comp, &u)
        if status1 != noErr {
            print("❌ AudioComponentInstanceNew input failed with error \(status1)")
            throw NSError(domain: "HAL", code: Int(status1))
        }
        unit = u
        
        // Enable input on bus 1, disable output on bus 0
        var enableIO: UInt32 = 1
        let status2 = AudioUnitSetProperty(u!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableIO, UInt32(MemoryLayout.size(ofValue: enableIO)))
        if status2 != noErr {
            print("❌ Enable input failed with error \(status2)")
        }
        
        var disableIO: UInt32 = 0
        let status3 = AudioUnitSetProperty(u!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disableIO, UInt32(MemoryLayout.size(ofValue: disableIO)))
        if status3 != noErr {
            print("❌ Disable output failed with error \(status3)")
        }
        
        // Bind to specific device
        var dev = deviceID
        print("🎤 Attempting to bind to device ID: \(deviceID)")
        let bindStatus = AudioUnitSetProperty(u!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout.size(ofValue: dev)))
        if bindStatus != noErr {
            print("❌ Failed to bind device: \(bindStatus)")
            throw NSError(domain: "HAL", code: Int(bindStatus))
        }
        print("✅ Device bound successfully")
        
        // Query the device's supported format
        var deviceASBD = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioUnitGetProperty(u!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &deviceASBD, &size)

        if status == noErr {
            print("📊 Device native format: \(deviceASBD.mSampleRate)Hz, \(deviceASBD.mChannelsPerFrame)ch")
            print("📊 Format flags: \(deviceASBD.mFormatFlags)")
            print("📊 Bits per channel: \(deviceASBD.mBitsPerChannel)")
            print("📊 Bytes per frame: \(deviceASBD.mBytesPerFrame)")
            hardwareFormat = StreamFormat(asbd: deviceASBD)
            
            // Check if non-interleaved
            let isNonInterleaved = (deviceASBD.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
            print("📊 Format is \(isNonInterleaved ? "non-interleaved" : "interleaved")")
            
            // Create a new format that's always interleaved - safer and easier to handle
            var newFormat = deviceASBD
            newFormat.mFormatFlags &= ~kAudioFormatFlagIsNonInterleaved  // Clear non-interleaved flag
            newFormat.mBytesPerFrame = UInt32(4 * Int(newFormat.mChannelsPerFrame))
            newFormat.mBytesPerPacket = newFormat.mBytesPerFrame
            
            // Set the format on the output scope (where we read from)
            let status4 = AudioUnitSetProperty(u!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &newFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
            if status4 != noErr {
                print("❌ Set device format output failed with error \(status4)")
            }
            
            // Update our format to match
            internalFormat = StreamFormat(asbd: newFormat)
        } else {
            print("⚠️ Could not query device format, using default")
            // Fall back to our default format - ensure it's interleaved
            var asbd = internalFormat.asbd
            asbd.mFormatFlags &= ~kAudioFormatFlagIsNonInterleaved  // Clear non-interleaved flag
            asbd.mBytesPerFrame = UInt32(4 * Int(asbd.mChannelsPerFrame))
            asbd.mBytesPerPacket = asbd.mBytesPerFrame
            
            let status5 = AudioUnitSetProperty(u!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
            if status5 != noErr {
                print("❌ Set input stream format output failed with error \(status5)")
            }
            
            // Update our format
            internalFormat = StreamFormat(asbd: asbd)
        }
        
        // Set up the render callback
        let ctx = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var cb = AURenderCallbackStruct(
            inputProc: { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData -> OSStatus in
                let ref = Unmanaged<InputDevice>.fromOpaque(inRefCon).takeUnretainedValue()
                return ref.onRender(inNumberFrames: inNumberFrames)
            },
            inputProcRefCon: ctx
        )
        
        // Use the correct property for input callback
        let status6 = AudioUnitSetProperty(u!,
                                   kAudioOutputUnitProperty_SetInputCallback,
                                   kAudioUnitScope_Global,
                                   0,
                                   &cb,
                                   UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        if status6 != noErr {
            print("❌ Set input callback failed with error \(status6)")
        }
        
        // Initialize the Audio Unit
        let status7 = AudioUnitInitialize(u!)
        if status7 != noErr {
            print("❌ Initialize input AUHAL failed with error \(status7)")
        }
    }
    
    func start() {
        isRunning = true
        
        if isTestTone {
            print("🎤 Starting test tone generator")
            // Prime downstream consumers with a few buffers
            for _ in 0..<bufferCount {
                emitTestTone(frames: framesPerBuffer)
            }
            
            // Emit tone at roughly the buffer cadence
            let sampleRate = internalFormat.sampleRate > 0 ? internalFormat.sampleRate : 44_100
            let interval = Double(framesPerBuffer) / sampleRate
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                guard let self = self, self.isRunning else { return }
                self.emitTestTone(frames: self.framesPerBuffer)
            }
        } else {
            print("🎤 Starting real device input")
            if let u = unit {
                let status = AudioOutputUnitStart(u)
                print("🎤 Starting input device: status = \(status)")
                if status != noErr {
                    print("❌ Failed to start input device: \(status)")
                }
            }
        }
    }
    
    func stop() {
        isRunning = false
        
        if isTestTone {
            print("🎤 Stopping test tone generator")
            timer?.invalidate()
            timer = nil
        } else {
            print("🎤 Stopping real device input")
            if let u = unit {
                let status = AudioOutputUnitStop(u)
                print("🎤 Stopping input device: status = \(status)")
            }
        }
    }
    
    private func emitTestTone(frames: Int) {
        let channels = max(Int(internalFormat.channelCount), 1)
        let samples = frames * channels
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: samples)
        
        let sampleRate = internalFormat.sampleRate > 0 ? internalFormat.sampleRate : 44_100
        for frame in 0..<frames {
            let time = Double(sampleCount + frame) / sampleRate
            let sample = Float(amplitude * sin(2.0 * .pi * frequency * time))
            for channel in 0..<channels {
                buffer[frame * channels + channel] = sample
            }
        }
        sampleCount += frames
        handler(buffer, frames, channels)
        buffer.deallocate()
    }
    
    private func mixTestTone(into buffer: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        let sampleRate = internalFormat.sampleRate > 0 ? internalFormat.sampleRate : 44_100
        for frame in 0..<frames {
            let time = Double(sampleCount + frame) / sampleRate
            let sample = Float(amplitude * 0.25 * sin(2.0 * .pi * frequency * time))
            for channel in 0..<channels {
                buffer[frame * channels + channel] += sample
            }
        }
        sampleCount += frames
    }
    
    private func onRender(inNumberFrames: UInt32) -> OSStatus {
        guard let unit = unit else { return noErr }

        let channels = max(Int(internalFormat.channelCount), 1)
        let frameCount = Int(inNumberFrames)
        let sampleCountForBuffer = frameCount * channels

        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: sampleCountForBuffer)
        defer { buffer.deallocate() }

        var abl = AudioBufferList()
        abl.mNumberBuffers = 1
        abl.mBuffers.mNumberChannels = UInt32(channels)
        abl.mBuffers.mDataByteSize = inNumberFrames * UInt32(channels) * 4
        abl.mBuffers.mData = UnsafeMutableRawPointer(buffer)

        var flags: AudioUnitRenderActionFlags = []
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = [.sampleTimeValid, .hostTimeValid]

        let status = AudioUnitRender(unit, &flags, &timestamp, 1, inNumberFrames, &abl)

        if status != noErr {
            print("❌ AudioUnitRender failed: \(status)")
            emitTestTone(frames: frameCount)
            callCount += 1
            return status
        }

        var maxSample: Float = 0.0
        var rmsLevel: Float = 0.0
        let analysisSamples = min(sampleCountForBuffer, 100)
        if analysisSamples > 0 {
            for i in 0..<analysisSamples {
                let sample = abs(buffer[i])
                maxSample = max(maxSample, sample)
                rmsLevel += sample * sample
            }
            rmsLevel = sqrt(rmsLevel / Float(analysisSamples))
        }

        callCount += 1

        if maxSample < 0.01 {
            let gain: Float = 20.0
            for i in 0..<sampleCountForBuffer {
                buffer[i] *= gain
            }
            if callCount % 100 == 0 {
                print("🎤 Amplifying weak signal: original max \(maxSample), amplified max \(min(maxSample * gain, 1.0)), RMS: \(rmsLevel)")
            }
        } else if callCount % 100 == 0 {
            print("🎤 Real device max sample: \(maxSample), RMS: \(rmsLevel)")
        }

        let noiseGate: Float = 0.001
        for i in 0..<sampleCountForBuffer {
            if abs(buffer[i]) < noiseGate {
                buffer[i] = 0.0
            }
        }

        if maxSample < 0.0005 && callCount % 3 == 0 {
            mixTestTone(into: buffer, frames: frameCount, channels: channels)
            if callCount % 300 == 0 {
                print("🎶 Mixed in test tone due to extremely weak signal")
            }
        }

        handler(buffer, frameCount, channels)
        return noErr
    }
}
