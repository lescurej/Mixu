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
    private let input: InputDevice
    private let lock = OSAllocatedUnfairLock()

    private var routes: [UUID: AudioRingBuffer] = [:]

    init(uid: String, deviceID: AudioDeviceID, format: StreamFormat, useTestTone: Bool) throws {
        self.uid = uid
        self.input = try InputDevice(deviceID: deviceID, format: format, useTestTone: useTestTone) { [weak self] buffer, frames in
            self?.dispatch(buffer: buffer, frames: frames)
        }
    }

    func start() {
        input.start()
    }

    func stop() {
        input.stop()
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

    private func dispatch(buffer: UnsafePointer<Float>, frames: Int) {
        lock.lock()
        let targets = Array(routes.values)
        lock.unlock()

        guard !targets.isEmpty else { return }

        for ring in targets {
            ring.write(buffer, frames: frames)
        }
    }
}
