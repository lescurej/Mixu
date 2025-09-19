//
//  AudioDestination.swift
//  Mixu
//
//  Created by Johan Lescure on 15/09/2025.
//

import AudioToolbox
import Foundation
import os.lock

final class AudioDestination {
    let uid: String
    private var sink: OutputSink?
    private let format: StreamFormat
    private let lock = OSAllocatedUnfairLock()

    private var routes: [UUID: AudioRingBuffer] = [:]

    init(uid: String, deviceID: AudioDeviceID, format: StreamFormat) throws {
        self.uid = uid
        self.format = format

        print("Creating destination for device: \(deviceID)")
        print("Format: sampleRate=\(format.asbd.mSampleRate), channels=\(format.asbd.mChannelsPerFrame), bits=\(format.asbd.mBitsPerChannel)")
        print("Format flags: \(format.asbd.mFormatFlags)")
        print("Bytes per frame: \(format.asbd.mBytesPerFrame)")
        print("Frames per packet: \(format.asbd.mFramesPerPacket)")

        do {
            sink = try OutputSink(deviceID: deviceID, internalFormat: format) { [weak self] bufferList, frameCapacity in
                guard let self else { return 0 }
                return self.render(into: bufferList, frameCapacity: frameCapacity)
            }
            print("Successfully created OutputSink for device \(deviceID)")
        } catch {
            print("Failed to create OutputSink for device \(deviceID): \(error)")
            throw error
        }
    }

    func start() {
        sink?.start()
    }

    func stop() {
        sink?.stop()
    }

    func addRoute(id: UUID, ring: AudioRingBuffer) {
        lock.lock()
        routes[id] = ring
        lock.unlock()
    }

    func removeRoute(id: UUID) -> Bool {
        lock.lock()
        routes.removeValue(forKey: id)
        let hasRoutes = !routes.isEmpty
        lock.unlock()
        return hasRoutes
    }

    private func render(into bufferList: UnsafeMutableAudioBufferListPointer, frameCapacity: Int) -> Int {
        guard frameCapacity > 0 else { return 0 }

        zero(bufferList: bufferList)

        lock.lock()
        let activeRoutes = Array(routes.values)
        lock.unlock()

        guard !activeRoutes.isEmpty else { return 0 }

        let channels = Int(format.asbd.mChannelsPerFrame)
        let temp = UnsafeMutablePointer<Float>.allocate(capacity: frameCapacity * channels)
        defer { temp.deallocate() }

        var producedFrames = 0

        for ring in activeRoutes {
            let framesRead = ring.read(into: temp, frames: frameCapacity)
            producedFrames = max(producedFrames, framesRead)
            mix(buffer: temp, frames: framesRead, into: bufferList, channels: channels)
        }

        updateByteSizes(bufferList: bufferList, frames: producedFrames, channels: channels)
        return producedFrames
    }

    private func zero(bufferList: UnsafeMutableAudioBufferListPointer) {
        for buffer in bufferList {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
    }

    private func mix(buffer: UnsafePointer<Float>, frames: Int, into bufferList: UnsafeMutableAudioBufferListPointer, channels: Int) {
        guard frames > 0 else { return }

        if bufferList.count == 1 {
            guard let data = bufferList[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let index = frame * channels + channel
                    data[index] = clamp(data[index] + buffer[index])
                }
            }
        } else {
            for channel in 0..<min(channels, bufferList.count) {
                guard let data = bufferList[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in 0..<frames {
                    let index = frame * channels + channel
                    data[frame] = clamp(data[frame] + buffer[index])
                }
            }
        }
    }

    private func updateByteSizes(bufferList: UnsafeMutableAudioBufferListPointer, frames: Int, channels: Int) {
        guard frames > 0 else { return }

        if bufferList.count == 1 {
            bufferList[0].mDataByteSize = UInt32(frames * channels * MemoryLayout<Float>.size)
        } else {
            for channel in 0..<bufferList.count {
                bufferList[channel].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
            }
        }
    }

    private func clamp(_ value: Float) -> Float {
        return max(-1.0, min(1.0, value))
    }
}
