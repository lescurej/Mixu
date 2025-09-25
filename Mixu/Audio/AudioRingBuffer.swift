//
//  AudioRingBuffer.swift
//  Mixu
//
//  Created by Johan Lescure on 15/09/2025.
//

import os.lock
import Foundation

/// Lock-based Ring Buffer (Swift 6 safe).
/// Single-producer / single-consumer. Uses OSAllocatedUnfairLock.
final class AudioRingBuffer {
    private let capacityFrames: Int
    private var buffer: [Float]
    private var writeIndex: Int = 0
    private var availableFrames: Int = 0
    private let lock = OSAllocatedUnfairLock()
    
    // Logging
    private var writeCount: Int = 0
    private var readCount: Int = 0
    private var lastLogTime: CFAbsoluteTime = 0
    private let logInterval: CFAbsoluteTime = 1.0 // Log every second

    init(capacityFrames: Int) {
        self.capacityFrames = capacityFrames
        self.buffer = Array(repeating: 0, count: capacityFrames)
        print("🔧 AudioRingBuffer: Created with capacity \(capacityFrames) frames")
    }

    func write(_ input: UnsafePointer<Float>, frames: Int) {
        let totalSamples = frames
        let cap = capacityFrames

        lock.lock()
        let fillLevelBefore = Double(availableFrames) / Double(capacityFrames)
        
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
        
        writeCount += 1
        
        lock.unlock()
    }

    /// Copy out up to `frames` frames. If underflow, fill rest with zeros.
    func read(into output: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        lock.lock()

        let framesToRead = min(frames, availableFrames)  // FIXED: Use min() to respect available data
        let samplesToRead = framesToRead
        let cap = capacityFrames
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
        readCount += 1

        // Fill remainder with zeros if asked for more
        if framesToRead < frames {
            let deficit = (frames - framesToRead)
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
    
    /// Get detailed status for debugging
    func getStatus() -> (fillLevel: Double, availableFrames: Int, capacityFrames: Int, writeCount: Int, readCount: Int) {
        lock.lock()
        let status = (
            fillLevel: Double(availableFrames) / Double(capacityFrames),
            availableFrames: availableFrames,
            capacityFrames: capacityFrames,
            writeCount: writeCount,
            readCount: readCount
        )
        lock.unlock()
        return status
    }
}
