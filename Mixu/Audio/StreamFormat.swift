//
//  StreamFormat.swift
//  Mixu
//
//  Created by Johan Lescure on 15/09/2025.
//

import AVFoundation

// MARK: - Formats
struct StreamFormat {
    var asbd: AudioStreamBasicDescription

    var channelCount: Int { Int(asbd.mChannelsPerFrame) }
    var sampleRate: Double { asbd.mSampleRate }

    static func make(sampleRate: Double, channels: UInt32) -> StreamFormat {
        var f = AudioStreamBasicDescription()
        f.mSampleRate = sampleRate
        f.mFormatID = kAudioFormatLinearPCM
        f.mFormatFlags = kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked
        f.mBitsPerChannel = 32
        f.mChannelsPerFrame = channels
        f.mBytesPerFrame = 4 * channels
        f.mFramesPerPacket = 1
        f.mBytesPerPacket = f.mBytesPerFrame
        return StreamFormat(asbd: f)
    }
    
    // Create a safe format that's guaranteed to work with AVAudioFormat
    static func makeSafe(sampleRate: Double, channels: UInt32) -> StreamFormat {
        // Ensure sample rate is reasonable
        let safeSampleRate = max(8000, min(192000, sampleRate))
        // Ensure channel count is reasonable
        let safeChannels = max(1, min(8, channels))
        
        return make(sampleRate: safeSampleRate, channels: safeChannels)
    }
    
    // Create non-interleaved format for unlimited channels
    static func makeNonInterleaved(sampleRate: Double, channels: UInt32) -> StreamFormat {
        var f = AudioStreamBasicDescription()
        f.mSampleRate = sampleRate
        f.mFormatID = kAudioFormatLinearPCM
        f.mFormatFlags = kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked | kLinearPCMFormatFlagIsNonInterleaved
        f.mBitsPerChannel = 32
        f.mChannelsPerFrame = channels
        f.mBytesPerFrame = 4 * channels
        f.mFramesPerPacket = 1
        f.mBytesPerPacket = f.mBytesPerFrame
        return StreamFormat(asbd: f)
    }
    
    // Check if format is interleaved
    var isInterleaved: Bool {
        return (asbd.mFormatFlags & kLinearPCMFormatFlagIsNonInterleaved) == 0
    }
    
    // Debug description
    var debugDescription: String {
        return "StreamFormat(sampleRate: \(asbd.mSampleRate), channels: \(asbd.mChannelsPerFrame), interleaved: \(isInterleaved))"
    }
    
    // Validate format before use
    var isValid: Bool {
        return asbd.mSampleRate > 0 && 
               asbd.mChannelsPerFrame > 0 && 
               asbd.mFormatID == kAudioFormatLinearPCM
    }
}
