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

    private func renderOutput(inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard let converter = converter else { return noErr }

        // Adjust SRC rate slightly based on ring fill (simple PLL)
        let error = ring.fillLevel() - targetFill
        let ppm = kp * error
        if abs(ppm - correctionPPM) > 1.0 { // avoid thrashing; 1 ppm threshold
            correctionPPM = ppm
            let ratio = (outFormat.asbd.mSampleRate * (1.0 + correctionPPM / 1_000_000.0)) / inFormat.asbd.mSampleRate
            // Undocumented but widely used KVC to steer converter rate a few ppm
            converter.setValue(ratio, forKey: "sampleRateConverterRate")
        }

        // Pull from ring buffer
        let framesNeeded = Int(inNumberFrames)
        let channels = Int(inFormat.asbd.mChannelsPerFrame)
        let tmp = UnsafeMutablePointer<Float>.allocate(capacity: framesNeeded * channels)
        let pulled = ring.read(into: tmp, frames: framesNeeded)

        let inAVFormat = AVAudioFormat(streamDescription: &inFormat.asbd)!
        let srcBuffer = AVAudioPCMBuffer(pcmFormat: inAVFormat, frameCapacity: AVAudioFrameCount(pulled))!
        srcBuffer.frameLength = AVAudioFrameCount(pulled)
        // Interleaved float: single pointer with all samples
        srcBuffer.floatChannelData!.pointee.update(from: tmp, count: pulled * channels)
        tmp.deallocate()

        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if srcBuffer.frameLength == 0 {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return srcBuffer
        }

        // Destination buffer
        let dstFormat = AVAudioFormat(streamDescription: &outFormat.asbd)!
        let dst = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: AVAudioFrameCount(inNumberFrames))!

        var convError: NSError?
        let status = converter.convert(to: dst, error: &convError, withInputFrom: inputBlock)

        if status != .haveData || convError != nil {
            os_log("Converter error: %{public}@", log: log, type: .error, String(describing: convError))
            // Output silence
            let buffers = UnsafeMutableAudioBufferListPointer(ioData)
            for i in 0..<buffers.count {
                memset(buffers[i].mData, 0, Int(buffers[i].mDataByteSize))
            }
            return noErr
        }

        // Copy dst into ioData (handle interleaved vs non-interleaved)
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        let outFrames = Int(dst.frameLength)
        let outCh = Int(outFormat.asbd.mChannelsPerFrame)

        if buffers.count == 1 {
            // Interleaved into a single buffer
            let dstPtr = dst.floatChannelData!.pointee
            let bytes = outFrames * outCh * MemoryLayout<Float>.size
            memcpy(buffers[0].mData, dstPtr, bytes)
            buffers[0].mDataByteSize = UInt32(bytes)
        } else {
            // Non-interleaved: copy channel by channel
            let framesBytes = outFrames * MemoryLayout<Float>.size
            for ch in 0..<min(buffers.count, outCh) {
                if let chPtr = dst.floatChannelData?[ch] {
                    memcpy(buffers[ch].mData, chPtr, framesBytes)
                    buffers[ch].mDataByteSize = UInt32(framesBytes)
                }
            }
        }

        return noErr
    }

    func start() { if let u = unit { check(AudioOutputUnitStart(u), "Start output AUHAL") } }
    func stop()  { if let u = unit { check(AudioOutputUnitStop(u),  "Stop output AUHAL") } }
}
