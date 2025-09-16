//
//  InputDevice.swift
//  Mixu
//
//  Created by Johan Lescure on 15/09/2025.
//

import AudioToolbox

// MARK: - Input (AUHAL) — reads from virtual device (e.g., BlackHole)
final class InputDevice {
    private var unit: AudioUnit?
    private let deviceID: AudioDeviceID
    private let format: StreamFormat
    private let ring: AudioRingBuffer

    init(deviceID: AudioDeviceID, format: StreamFormat, ring: AudioRingBuffer) throws {
        self.deviceID = deviceID
        self.format = format
        self.ring = ring
        try setup()
    }

    private func setup() throws {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw NSError(domain: "HAL", code: -1) }
        var u: AudioUnit?
        check(AudioComponentInstanceNew(comp, &u), "AudioComponentInstanceNew input")
        unit = u

        var enableIO: UInt32 = 1
        check(AudioUnitSetProperty(u!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enableIO, UInt32(MemoryLayout.size(ofValue: enableIO))), "Enable output")
        // Enable input on bus 1 (input scope)
        check(AudioUnitSetProperty(u!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableIO, UInt32(MemoryLayout.size(ofValue: enableIO))), "Enable input")
        // Disable output on bus 0
        var disableIO: UInt32 = 0
        check(AudioUnitSetProperty(u!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disableIO, UInt32(MemoryLayout.size(ofValue: disableIO))), "Disable output")

        // Bind to specific device
        var dev = deviceID
        check(AudioUnitSetProperty(u!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout.size(ofValue: dev))), "Bind input device")

        var asbd = format.asbd
        check(AudioUnitSetProperty(u!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Set input stream format")

        let ctx = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var cb = AURenderCallbackStruct(
            inputProc: { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData -> OSStatus in
                let ref = Unmanaged<InputDevice>.fromOpaque(inRefCon).takeUnretainedValue()
                return ref.onRender(inNumberFrames: inNumberFrames)
            },
            inputProcRefCon: ctx
        )
        check(AudioUnitSetProperty(u!,
                                   kAudioOutputUnitProperty_SetInputCallback,
                                   kAudioUnitScope_Global,
                                   0,
                                   &cb,
                                   UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
              "Set input callback")

        check(AudioUnitInitialize(u!), "Initialize input AUHAL")
    }

    private func onRender(inNumberFrames: UInt32) -> OSStatus {
        guard let unit = unit else { return noErr }
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: format.asbd.mChannelsPerFrame,
                                  mDataByteSize: inNumberFrames * format.asbd.mBytesPerFrame,
                                  mData: nil)
        )
        var flags: AudioUnitRenderActionFlags = []
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = [.sampleTimeValid, .hostTimeValid] // ✅ en Swift
        
        let status = AudioUnitRender(unit, &flags, &timestamp, 1, inNumberFrames, &bufferList)
        if status != noErr { return status }
        guard let mData = bufferList.mBuffers.mData else { return noErr }
        let ptr = mData.assumingMemoryBound(to: Float.self)
        ring.write(ptr, frames: Int(inNumberFrames))
        return noErr
    }


    func start() { if let u = unit { check(AudioOutputUnitStart(u), "Start input AUHAL") } }
    func stop()  { if let u = unit { check(AudioOutputUnitStop(u),  "Stop input AUHAL") } }
}
