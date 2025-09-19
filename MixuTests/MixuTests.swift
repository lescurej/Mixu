//
//  MixuTests.swift
//  MixuTests
//
//  Created by Johan Lescure on 15/09/2025.
//

import Testing
@testable import Mixu

struct MixuTests {

    @Test("Ring buffer preserves audio samples across write/read cycles")
    func ringBufferRoundTrip() throws {
        let channels = 2
        let capacity = 256
        let ring = AudioRingBuffer(capacityFrames: capacity, channels: channels)

        var samples: [Float] = []
        for frame in 0..<capacity {
            let left = Float(frame) / Float(capacity)
            let right = -left
            samples.append(contentsOf: [left, right])
        }

        samples.withUnsafeBufferPointer { pointer in
            ring.write(pointer.baseAddress!, frames: capacity)
        }

        let output = UnsafeMutablePointer<Float>.allocate(capacity: capacity * channels)
        defer { output.deallocate() }

        let framesRead = ring.read(into: output, frames: capacity)
        #expect(framesRead == capacity)

        for index in 0..<(capacity * channels) {
            #expect(output[index] == samples[index])
        }
        #expect(ring.fillLevel() == 0)
    }

    @Test("Ring buffer clears unread frames on underflow")
    func ringBufferUnderflow() throws {
        let channels = 2
        let capacity = 64
        let ring = AudioRingBuffer(capacityFrames: capacity, channels: channels)

        let framesToWrite = capacity / 2
        var samples = Array(repeating: Float(0.5), count: framesToWrite * channels)
        samples.withUnsafeMutableBufferPointer { pointer in
            ring.write(pointer.baseAddress!, frames: framesToWrite)
        }

        let output = UnsafeMutablePointer<Float>.allocate(capacity: capacity * channels)
        defer { output.deallocate() }

        let framesRead = ring.read(into: output, frames: capacity)
        #expect(framesRead == framesToWrite)

        for index in 0..<(framesToWrite * channels) {
            #expect(output[index] == 0.5)
        }

        for index in (framesToWrite * channels)..<(capacity * channels) {
            #expect(output[index] == 0)
        }

        #expect(ring.fillLevel() == 0)
    }
}
