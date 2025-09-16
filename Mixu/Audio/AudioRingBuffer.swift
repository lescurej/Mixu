//
//  AudioRingBuffer.swift
//  Mixu
//
//  Created by Johan Lescure on 15/09/2025.
//

import os.log

/// Lock-based Ring Buffer (Swift 6 safe).
/// Single-producer / single-consumer. Uses OSAllocatedUnfairLock.
final class AudioRingBuffer {
    private let capacityFrames: Int
    private let channels: Int
    private var buffer: [Float]
    private var writeIndex: Int = 0
    private var availableFrames: Int = 0
    private let lock = OSAllocatedUnfairLock()

    init(capacityFrames: Int, channels: Int) {
        self.capacityFrames = capacityFrames
        self.channels = channels
        self.buffer = Array(repeating: 0, count: capacityFrames * channels)
    }

    func write(_ input: UnsafePointer<Float>, frames: Int) {
        let totalSamples = frames * channels
        let cap = capacityFrames * channels

        lock.lock()
        var remaining = totalSamples
        var src = input
        while remaining > 0 {
            let space = cap - writeIndex
            let n = min(remaining, space)
            buffer.withUnsafeMutableBufferPointer { dstBuf in
                let dst = dstBuf.baseAddress!.advanced(by: writeIndex)
                memcpy(dst, src, n * MemoryLayout<Float>.size)
            }
            remaining -= n
            src = src.advanced(by: n)
            writeIndex = (writeIndex + n) % cap
        }
        availableFrames = min(capacityFrames, availableFrames + frames)
        lock.unlock()
    }

    /// Copy out up to `frames` frames. If underflow, fill rest with zeros.
    func read(into output: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        lock.lock()

        let framesToRead = min(frames, availableFrames)
        let samplesToRead = framesToRead * channels
        let cap = capacityFrames * channels
        let readIndex = (writeIndex - samplesToRead + cap) % cap

        buffer.withUnsafeBufferPointer { srcBuf in
            let src = srcBuf.baseAddress!
            // First chunk
            let first = min(samplesToRead, cap - readIndex)
            memcpy(output, src.advanced(by: readIndex), first * MemoryLayout<Float>.size)
            // Wrap chunk
            let second = samplesToRead - first
            if second > 0 {
                memcpy(output.advanced(by: first), src, second * MemoryLayout<Float>.size)
            }
        }

        availableFrames -= framesToRead

        // Fill remainder with zeros if asked for more
        if framesToRead < frames {
            let deficit = (frames - framesToRead) * channels
            memset(output.advanced(by: samplesToRead), 0, deficit * MemoryLayout<Float>.size)
        }

        lock.unlock()
        return framesToRead
    }

    /// Normalized fill level (0..1)
    func fillLevel() -> Double {
        lock.lock()
        let level = Double(availableFrames) / Double(capacityFrames)
        lock.unlock()
        return level
    }
}
