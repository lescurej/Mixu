//
//  AudioSource.swift
//  Mixu
//
//  Created by Johan Lescure on 15/09/2025.
//

import CoreAudio
import Foundation
import os.lock

final class AudioSource {
    let uid: String
    private var input: InputDevice!
    private let lock = OSAllocatedUnfairLock()
    let channelCount: Int

    struct Route {
        let ring: AudioRingBuffer
        let channelOffset: Int
    }

    var routes: [UUID: Route] = [:]
    
    // Logging
    private var lastLogTime: CFAbsoluteTime = 0
    private let logInterval: CFAbsoluteTime = 2.0 // Log every 2 seconds
    private var totalFramesDispatched: Int = 0

    init(uid: String, deviceID: AudioDeviceID, deviceFormat: StreamFormat, internalFormat: StreamFormat) throws {
        print(" AudioSource.init: uid=\(uid), deviceID=\(deviceID), channels=\(internalFormat.channelCount)")
        self.uid = uid
        self.channelCount = internalFormat.channelCount

        let handler: InputDevice.SampleHandler = { [weak self] buffer, frames, channelCount in
            self?.dispatch(buffer: buffer, frames: frames, channelCount: channelCount)
        }

        self.input = try InputDevice(
            deviceID: deviceID,
            deviceFormat: deviceFormat,
            internalFormat: internalFormat,
            handler: handler
        )
    }

    func start() {
        print("▶️ AudioSource.start: uid=\(uid)")
        input.start()
    }

    func stop() {
        print("⏹️ AudioSource.stop: uid=\(uid)")
        input.stop()
    }

    func addRoute(id: UUID, ring: AudioRingBuffer, channelOffset: Int) {
        print("🔗 AudioSource.addRoute: uid=\(uid), routeId=\(id), channelOffset=\(channelOffset)")
        lock.lock()
        routes[id] = Route(ring: ring, channelOffset: channelOffset)
        lock.unlock()
    }

    func removeRoute(id: UUID) -> Bool {
        print(" AudioSource.removeRoute: uid=\(uid), routeId=\(id)")
        lock.lock()
        routes.removeValue(forKey: id)
        let hasRoutes = !routes.isEmpty
        lock.unlock()
        return hasRoutes
    }

    private func dispatch(buffer: UnsafePointer<Float>, frames: Int, channelCount: Int) {
        guard frames > 0, channelCount > 0 else { return }
        totalFramesDispatched += frames
        
        lock.lock()
        let targets = Array(routes.values)
        lock.unlock()

        guard !targets.isEmpty else { 
            print("⚠️ AudioSource.dispatch: No routes available for \(uid)")
            return 
        }

        var channelSamples = Array<Float>(repeating: 0, count: frames)

        for route in targets {
            let offset = route.channelOffset

            channelSamples.withUnsafeMutableBufferPointer { dest in
                guard let destBase = dest.baseAddress else { return }

                if offset < channelCount {
                    for frameIndex in 0..<frames {
                        destBase[frameIndex] = buffer[frameIndex * channelCount + offset]
                    }
                } else {
                    for frameIndex in 0..<frames {
                        destBase[frameIndex] = 0
                    }
                }
            }

            channelSamples.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                route.ring.write(base, frames: frames)
            }
        }
    }
}
