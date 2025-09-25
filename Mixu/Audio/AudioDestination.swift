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
    private final class RenderProxy {
        weak var destination: AudioDestination?

        func render(into bufferList: UnsafeMutableAudioBufferListPointer, frameCapacity: Int) -> Int {
            return destination?.renderInternal(into: bufferList, frameCapacity: frameCapacity) ?? 0
        }
    }

    let uid: String
    private let sink: OutputSink
    private let internalFormat: StreamFormat
    let channelCount: Int
    private let lock = OSAllocatedUnfairLock()

    private let renderProxy: RenderProxy

    var routes: [UUID: AudioRingBuffer] = [:]
    
    // Logging
    private var lastLogTime: CFAbsoluteTime = 0
    private let logInterval: CFAbsoluteTime = 2.0
    private var totalFramesRendered: Int = 0

    init(uid: String, deviceID: AudioDeviceID, deviceFormat: StreamFormat, internalFormat: StreamFormat, channelOffset: Int) throws {
        print("🔊 AudioDestination.init: uid=\(uid), deviceID=\(deviceID)")
        print("  deviceFormat: \(deviceFormat.debugDescription)")
        print("  internalFormat: \(internalFormat.debugDescription)")
        print("  deviceFormat channels: \(deviceFormat.channelCount)")
        print("  deviceFormat sampleRate: \(deviceFormat.sampleRate)")
        print("  channelOffset: \(channelOffset)")
        
        let proxy = RenderProxy()

        self.uid = uid
        self.internalFormat = internalFormat
        self.channelCount = internalFormat.channelCount
        self.renderProxy = proxy
        let sink: OutputSink
        do {
            sink = try OutputSink(
                deviceID: deviceID,
                deviceFormat: deviceFormat,
                internalFormat: internalFormat,
                channelOffset: channelOffset,
                provider: { [weak proxy] bufferList, frameCapacity in
                    proxy?.render(into: bufferList, frameCapacity: frameCapacity) ?? 0
                }
            )
        } catch {
            print("❌ AudioDestination.init: Failed to create OutputSink: \(error)")
            throw error
        }
        self.sink = sink
        proxy.destination = self
    }

    func start() {
        print("▶️ AudioDestination.start: uid=\(uid)")
        sink.start()
    }

    func stop() {
        print("⏹️ AudioDestination.stop: uid=\(uid)")
        sink.stop()
    }

    func addRoute(id: UUID, ring: AudioRingBuffer) {
        print("🔗 AudioDestination.addRoute: uid=\(uid), routeId=\(id)")
        lock.lock()
        routes[id] = ring
        lock.unlock()
    }

    func removeRoute(id: UUID) -> Bool {
        print("🔌 AudioDestination.removeRoute: uid=\(uid), routeId=\(id)")
        lock.lock()
        routes.removeValue(forKey: id)
        let hasRoutes = !routes.isEmpty
        lock.unlock()
        return hasRoutes
    }

    private func renderInternal(into bufferList: UnsafeMutableAudioBufferListPointer, frameCapacity: Int) -> Int {
        guard frameCapacity > 0 else { return 0 }

        zero(bufferList: bufferList)

        lock.lock()
        let activeRoutes = Array(routes.values)
        lock.unlock()

        guard !activeRoutes.isEmpty else { 
            print("⚠️ AudioDestination.renderInternal: No routes available for \(uid)")
            return 0 
        }

        let channels = channelCount
        let temp = UnsafeMutablePointer<Float>.allocate(capacity: frameCapacity * channels)
        defer { temp.deallocate() }

        var producedFrames = 0

        for (index, ring) in activeRoutes.enumerated() {
            let fillLevelBefore = ring.fillLevel()
            let framesRead = ring.read(into: temp, frames: frameCapacity)
            let fillLevelAfter = ring.fillLevel()
            producedFrames = max(producedFrames, framesRead)
            mix(buffer: temp, frames: framesRead, into: bufferList, channels: channels)
        }

        updateByteSizes(bufferList: bufferList, frames: producedFrames, channels: channels)
        totalFramesRendered += producedFrames
        
        return producedFrames
    }

    private func zero(bufferList: UnsafeMutableAudioBufferListPointer) {
        for i in 0..<bufferList.count {
                guard bufferList[i].mDataByteSize > 0, let data = bufferList[i].mData else { continue }
                memset(data, 0, Int(bufferList[i].mDataByteSize))
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
