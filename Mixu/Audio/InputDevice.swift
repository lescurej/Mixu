//
//  InputDevice.swift
//  Mixu
//
//  Created by Johan Lescure on 15/09/2025.
//

import AudioToolbox
import AVFoundation

// MARK: - Input Device (Real or Test Tone)
final class InputDevice {
    private var unit: AudioUnit?
    private var timer: Timer?
    private let deviceID: AudioDeviceID
    private var format: StreamFormat
    private let ring: AudioRingBuffer
    private var sampleCount: Int = 0
    private var isRunning = false
    private var isTestTone = false
    private var callCount: Int = 0
    
    // Constants for test tone generation
    private let sampleRate = 44100
    private let frequency = 440.0 // A4 note
    private let amplitude = 0.3
    private let framesPerBuffer = 512
    private let bufferCount = 3  // Number of buffers to keep filled
    
    init(deviceID: AudioDeviceID, format: StreamFormat, ring: AudioRingBuffer) throws {
        self.deviceID = deviceID
        self.format = format
        self.ring = ring
        
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
        var deviceFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioUnitGetProperty(u!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &deviceFormat, &size)
        
        if status == noErr {
            print("📊 Device native format: \(deviceFormat.mSampleRate)Hz, \(deviceFormat.mChannelsPerFrame)ch")
            print("📊 Format flags: \(deviceFormat.mFormatFlags)")
            print("📊 Bits per channel: \(deviceFormat.mBitsPerChannel)")
            print("📊 Bytes per frame: \(deviceFormat.mBytesPerFrame)")
            
            // Check if non-interleaved
            let isNonInterleaved = (deviceFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
            print("📊 Format is \(isNonInterleaved ? "non-interleaved" : "interleaved")")
            
            // Create a new format that's always interleaved - safer and easier to handle
            var newFormat = deviceFormat
            newFormat.mFormatFlags &= ~kAudioFormatFlagIsNonInterleaved  // Clear non-interleaved flag
            newFormat.mBytesPerFrame = UInt32(4 * Int(newFormat.mChannelsPerFrame))
            newFormat.mBytesPerPacket = newFormat.mBytesPerFrame
            
            // Set the format on the output scope (where we read from)
            let status4 = AudioUnitSetProperty(u!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &newFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
            if status4 != noErr {
                print("❌ Set device format output failed with error \(status4)")
            }
            
            // Update our format to match
            self.format = StreamFormat(asbd: newFormat)
        } else {
            print("⚠️ Could not query device format, using default")
            // Fall back to our default format - ensure it's interleaved
            var asbd = format.asbd
            asbd.mFormatFlags &= ~kAudioFormatFlagIsNonInterleaved  // Clear non-interleaved flag
            asbd.mBytesPerFrame = UInt32(4 * Int(asbd.mChannelsPerFrame))
            asbd.mBytesPerPacket = asbd.mBytesPerFrame
            
            let status5 = AudioUnitSetProperty(u!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
            if status5 != noErr {
                print("❌ Set input stream format output failed with error \(status5)")
            }
            
            // Update our format
            self.format = StreamFormat(asbd: asbd)
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
            // Fill the buffer initially with multiple chunks
            for _ in 0..<bufferCount {
                generateTestTone()
            }
            
            // Start a timer to keep the buffer filled
            timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
                guard let self = self, self.isRunning else { return }
                
                // Only generate more audio if the buffer is getting low
                if self.ring.fillLevel() < 0.5 {
                    self.generateTestTone()
                }
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
    
    private func generateTestTone() {
        // Allocate buffer for stereo interleaved audio
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: framesPerBuffer * 2)
        defer { buffer.deallocate() }
        
        // Generate sine wave
        for i in 0..<framesPerBuffer {
            let time = Double(sampleCount + i) / Double(sampleRate)
            let sample = Float(amplitude * sin(2.0 * .pi * frequency * time))
            
            // Interleaved stereo (left, right)
            buffer[i * 2] = sample
            buffer[i * 2 + 1] = sample
        }
        
        // Update sample count
        sampleCount += framesPerBuffer
        
        // Write to ring buffer
        ring.write(buffer, frames: framesPerBuffer)
        
        // Periodically log the buffer fill level
        if sampleCount % (framesPerBuffer * 20) == 0 {
            print("🎤 Generated test tone: buffer fill level: \(ring.fillLevel())")
        }
    }
    
    private func onRender(inNumberFrames: UInt32) -> OSStatus {
        guard let unit = unit else { return noErr }
        
        // Check if ring buffer is getting too full
        let fillLevel = ring.fillLevel()
        if fillLevel > 0.9 {
            // Skip this frame to avoid buffer overflow
            if callCount % 50 == 0 {
                print("⚠️ Ring buffer nearly full (\(fillLevel)), skipping frame to prevent overflow")
            }
            callCount += 1
            return noErr
        }
        
        // Use a much simpler approach - allocate a single buffer for the audio data
        let channels = Int(format.asbd.mChannelsPerFrame)
        
        // Create a buffer to hold the audio data
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: Int(inNumberFrames) * channels)
        defer { buffer.deallocate() }
        
        // Create a simple AudioBufferList
        var abl = AudioBufferList()
        abl.mNumberBuffers = 1
        abl.mBuffers.mNumberChannels = UInt32(channels)
        abl.mBuffers.mDataByteSize = inNumberFrames * UInt32(channels) * 4
        abl.mBuffers.mData = UnsafeMutableRawPointer(buffer)
        
        // Call AudioUnitRender to get the audio data
        var flags: AudioUnitRenderActionFlags = []
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = [.sampleTimeValid, .hostTimeValid]
        
        // Call AudioUnitRender
        let status = AudioUnitRender(unit, &flags, &timestamp, 1, inNumberFrames, &abl)
        
        if status != noErr {
            print("❌ AudioUnitRender failed: \(status)")
            
            // Fall back to test tone if we can't get audio from the device
            generateTestTone()
            
            callCount += 1
            return status
        }
        
        // Check if we got any audio data
        var maxSample: Float = 0.0
        var rmsLevel: Float = 0.0
        
        for i in 0..<min(Int(inNumberFrames) * channels, 100) {
            let sample = abs(buffer[i])
            maxSample = max(maxSample, sample)
            rmsLevel += sample * sample
        }
        
        rmsLevel = sqrt(rmsLevel / Float(min(Int(inNumberFrames) * channels, 100)))
        
        // Only log occasionally to avoid spam
        callCount += 1
        
        // If the signal is too weak, amplify it significantly
        if maxSample < 0.01 {
            // Amplify the signal to make it more audible
            let gain: Float = 20.0 // Boost by 20x for very weak signals
            for i in 0..<Int(inNumberFrames) * channels {
                buffer[i] *= gain
            }
            
            if callCount % 100 == 0 {
                print("🎤 Amplifying weak signal: original max \(maxSample), amplified max \(min(maxSample * gain, 1.0)), RMS: \(rmsLevel)")
            }
        } else if callCount % 100 == 0 {
            print("🎤 Real device max sample: \(maxSample), RMS: \(rmsLevel), buffer fill level: \(fillLevel)")
        }
        
        // Apply a noise gate to remove very low level noise
        let noiseGate: Float = 0.001
        for i in 0..<Int(inNumberFrames) * channels {
            if abs(buffer[i]) < noiseGate {
                buffer[i] = 0.0
            }
        }
        
        // Write to ring buffer
        ring.write(buffer, frames: Int(inNumberFrames))
        
        // If signal is extremely weak, mix in a test tone to verify routing
        if maxSample < 0.0005 && callCount % 3 == 0 { // Only mix in occasionally to avoid constant tone
            // Mix in a moderate test tone to verify routing
            let mixBuffer = UnsafeMutablePointer<Float>.allocate(capacity: framesPerBuffer * 2)
            defer { mixBuffer.deallocate() }
            
            // Generate sine wave at 25% amplitude
            for i in 0..<framesPerBuffer {
                let time = Double(sampleCount + i) / Double(sampleRate)
                let sample = Float(amplitude * 0.25 * sin(2.0 * .pi * frequency * time))
                
                // Interleaved stereo (left, right)
                mixBuffer[i * 2] = sample
                mixBuffer[i * 2 + 1] = sample
            }
            
            // Update sample count
            sampleCount += framesPerBuffer
            
            // Write to ring buffer
            ring.write(mixBuffer, frames: framesPerBuffer)
            
            if callCount % 300 == 0 {
                print("�� Mixed in test tone due to extremely weak signal")
            }
        }
        
        return noErr
    }
}
