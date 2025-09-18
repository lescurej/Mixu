//
//  OutputSink.swift
//  Mixu
//
//  Created by Johan Lescure on 15/09/2025.
//

import AudioToolbox
import AVFoundation
import os.log

// MARK: - Per-Destination Output with Async SRC + Fill-Level PLL
final class OutputSink {
    private var unit: AudioUnit?
    private let deviceID: AudioDeviceID
    private var outFormat: StreamFormat
    private var inFormat: StreamFormat
    private let ring: AudioRingBuffer

    // SRC using AVAudioConverter for simplicity
    private var converter: AVAudioConverter!
    private var correctionPPM: Double = 0 // dynamic drift correction

    // Target fill control (keeps ring around this level to absorb jitter)
    private let targetFill: Double = 0.5 // 50% full
    private let kp: Double = 50.0       // proportional gain → adjust as needed (ppm per unit error)

    private var renderCount = 0

    init(deviceID: AudioDeviceID, inFormat: StreamFormat, outFormat: StreamFormat, ring: AudioRingBuffer) throws {
        self.deviceID = deviceID
        self.inFormat = inFormat
        self.outFormat = outFormat
        self.ring = ring
        try setup()
    }

    private func setup() throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_DefaultOutput, // 🔑
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw NSError(domain: "HAL", code: -2, userInfo: [NSLocalizedDescriptionKey: "HALOutput not found"])
        }
        var u: AudioUnit?
        check(AudioComponentInstanceNew(comp, &u), "AudioComponentInstanceNew output")
        unit = u

        // Enable output on bus 0
        var enableIO: UInt32 = 1
        check(AudioUnitSetProperty(u!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enableIO, UInt32(MemoryLayout.size(ofValue: enableIO))), "Enable output")
        // Disable input on bus 1
        var disableIO: UInt32 = 0
        check(AudioUnitSetProperty(u!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disableIO, UInt32(MemoryLayout.size(ofValue: disableIO))), "Disable input")

        // Bind to specific device
        var dev = deviceID
        check(AudioUnitSetProperty(u!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout.size(ofValue: dev))), "Bind output device")

        // Configure AU input format to match our output format (to the physical device)
        var outASBD = outFormat.asbd
        check(AudioUnitSetProperty(u!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &outASBD, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Set output stream format")

        // Render callback (6 params!)
        let ctx = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var cb = AURenderCallbackStruct(
            inputProc: { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData -> OSStatus in
                let ref = Unmanaged<OutputSink>.fromOpaque(inRefCon).takeUnretainedValue()
                return ref.renderOutput(inNumberFrames: inNumberFrames, ioData: ioData!)
            },
            inputProcRefCon: ctx
        )
        check(AudioUnitSetProperty(u!, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Set output render callback")

        check(AudioUnitInitialize(u!), "Initialize output AUHAL")

        // Create converter (input = ring format, output = AU/physical format)
        let inFormatAV = AVAudioFormat(streamDescription: &self.inFormat.asbd)!
        let outFormatAV = AVAudioFormat(streamDescription: &outASBD)!
        converter = AVAudioConverter(from: inFormatAV, to: outFormatAV)
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = .max
    }

    // Add more detailed logging to the OutputSink
    private func renderOutput(inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        // Get buffer list for easier access
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        
        // Log buffer details
        print("🔍 OutputSink renderOutput called:")
        print("  - Number of frames: \(inNumberFrames)")
        print("  - Number of buffers: \(buffers.count)")
        for i in 0..<buffers.count {
            print("  - Buffer \(i): \(buffers[i].mNumberChannels) channels, \(buffers[i].mDataByteSize) bytes")
        }
        
        // Check if ring buffer has data
        let fillLevel = ring.fillLevel()
        print("  - Ring buffer fill level: \(fillLevel)")
        
        if fillLevel == 0.0 {
            // Output silence if no data available
            for i in 0..<buffers.count {
                memset(buffers[i].mData, 0, Int(buffers[i].mDataByteSize))
            }
            return noErr
        }

        // Pull from ring buffer
        let framesNeeded = Int(inNumberFrames)
        let channels = Int(inFormat.asbd.mChannelsPerFrame)
        let tmp = UnsafeMutablePointer<Float>.allocate(capacity: framesNeeded * channels)
        defer { tmp.deallocate() }
        
        let pulled = ring.read(into: tmp, frames: framesNeeded)
        
        print("  - Pulled \(pulled) frames from ring buffer")
        
        if pulled == 0 {
            // Output silence if no data pulled
            for i in 0..<buffers.count {
                memset(buffers[i].mData, 0, Int(buffers[i].mDataByteSize))
            }
            return noErr
        }

        // Check if output is interleaved or non-interleaved
        let isOutputInterleaved = buffers.count == 1 && buffers[0].mNumberChannels > 1
        print("  - Output format is \(isOutputInterleaved ? "interleaved" : "non-interleaved")")
        
        if isOutputInterleaved {
            // For interleaved output, copy directly
            let bytesPerFrame = 4 * channels  // 4 bytes per sample (32-bit float) * channels
            let bytesToCopy = min(Int(buffers[0].mDataByteSize), pulled * bytesPerFrame)
            
            print("  - Copying \(bytesToCopy) bytes directly to interleaved output buffer")
            
            if let mData = buffers[0].mData {
                memcpy(mData, tmp, bytesToCopy)
            }
        } else {
            // For non-interleaved output, de-interleave our data
            print("  - De-interleaving data to \(buffers.count) output buffers")
            
            for ch in 0..<min(channels, buffers.count) {
                if let mData = buffers[ch].mData {
                    let outBuffer = mData.assumingMemoryBound(to: Float.self)
                    
                    // Copy each channel
                    for frame in 0..<pulled {
                        outBuffer[frame] = tmp[frame * channels + ch]
                    }
                }
            }
        }

        return noErr
    }

    func start() {
        guard let unit = unit else { return }
        let status = AudioOutputUnitStart(unit)
        print("🔊 Starting output device: status = \(status)")
        if status != noErr {
            print("❌ Failed to start output device: \(status)")
        }
    }

    func stop() {
        guard let unit = unit else { return }
        let status = AudioOutputUnitStop(unit)
        print("🔇 Stopping output device: status = \(status)")
    }
}
