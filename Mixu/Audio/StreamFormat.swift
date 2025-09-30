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

    static func make(sampleRate: Double, channels: UInt32) -> StreamFormat {
        var f = AudioStreamBasicDescription()
        f.mSampleRate = sampleRate
        f.mFormatID = kAudioFormatLinearPCM
        f.mFormatFlags = kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked
        f.mBitsPerChannel = 32
        f.mChannelsPerFrame = channels
        f.mBytesPerFrame = 4 * channels
        f.mFramesPerPacket = 1
        f.mBytesPerPacket = f.mBytesPerFrame * f.mFramesPerPacket
        return StreamFormat(asbd: f)
    }
}
