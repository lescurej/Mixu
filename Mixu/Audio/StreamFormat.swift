//
//  StreamFormat.swift
//  Mixu
//
//  Created by Johan Lescure on 15/09/2025.
//

import AudioToolbox

// MARK: - Formats
struct StreamFormat {
    var asbd: AudioStreamBasicDescription
    var sampleRate: Double
    var channelCount: UInt32

    static func make(sampleRate: Double, channelCount: UInt32) -> StreamFormat {
        var f = AudioStreamBasicDescription()
        f.mSampleRate = sampleRate
        f.mFormatID = kAudioFormatLinearPCM
        f.mFormatFlags = kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked
        f.mBitsPerChannel = 32
        f.mChannelsPerFrame = channelCount
        f.mBytesPerFrame = 4 * channelCount
        f.mFramesPerPacket = 1
        f.mBytesPerPacket = f.mBytesPerFrame * f.mFramesPerPacket
        return StreamFormat(asbd: f, sampleRate: sampleRate, channelCount: channelCount)
    }

    init(asbd: AudioStreamBasicDescription, sampleRate: Double, channelCount: UInt32) {
        self.asbd = asbd
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    init(asbd: AudioStreamBasicDescription) {
        self.init(asbd: asbd, sampleRate: asbd.mSampleRate, channelCount: asbd.mChannelsPerFrame)
    }

    var debugDescription: String {
        "SampleRate: \(asbd.mSampleRate), Channels: \(asbd.mChannelsPerFrame), BitsPerChannel: \(asbd.mBitsPerChannel), FormatID: \(asbd.mFormatID), FormatFlags: \(asbd.mFormatFlags)"
    }
}
