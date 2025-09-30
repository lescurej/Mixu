//
//  PluginNode.swift
//  Mixu
//
//  Created by Johan Lescure on 17/09/2025.
//

import Foundation
import os.lock

final class PluginNode {
    struct OutputRoute {
        let connectionID: UUID
        let ring: AudioRingBuffer
        let completion: ((AudioRingBuffer, Int) -> Void)?
    }

    private struct InputRoute {
        let connectionID: UUID
        let ring: AudioRingBuffer
    }

    let id: UUID
    let descriptor: AudioPluginDescriptor
    private(set) var channelCount: Int

    private var effectChain: AudioEffectChain?
    private var inputRoutes: [UUID: InputRoute] = [:]
    private var outputRoutes: [UUID: OutputRoute] = [:]

    private var processingBuffer: [Float] = []
    private let lock = OSAllocatedUnfairLock()

    init(id: UUID, descriptor: AudioPluginDescriptor, format: StreamFormat) {
        self.id = id
        self.descriptor = descriptor
        self.channelCount = format.channelCount
        reinitializeChain(with: format)
    }

    func reinitializeChain(with format: StreamFormat) {
        lock.lock()
        defer { lock.unlock() }
        effectChain = AudioEffectChain(descriptors: [descriptor], format: format)
        channelCount = format.channelCount
        processingBuffer = Array(repeating: 0, count: Int(format.channelCount) * 4096)
    }

    func addInputRoute(connectionID: UUID, ring: AudioRingBuffer) {
        lock.lock()
        inputRoutes[connectionID] = InputRoute(connectionID: connectionID, ring: ring)
        lock.unlock()
    }

    func removeInputRoute(connectionID: UUID) {
        lock.lock()
        inputRoutes.removeValue(forKey: connectionID)
        lock.unlock()
    }

    func addOutputRoute(connectionID: UUID, ring: AudioRingBuffer, completion: ((AudioRingBuffer, Int) -> Void)?) {
        lock.lock()
        outputRoutes[connectionID] = OutputRoute(connectionID: connectionID, ring: ring, completion: completion)
        lock.unlock()
    }

    func removeOutputRoute(connectionID: UUID) {
        lock.lock()
        outputRoutes.removeValue(forKey: connectionID)
        lock.unlock()
    }

    func removeAllRoutes() {
        lock.lock()
        inputRoutes.removeAll()
        outputRoutes.removeAll()
        lock.unlock()
    }

    func hasNoConnections() -> Bool {
        lock.lock()
        let empty = inputRoutes.isEmpty && outputRoutes.isEmpty
        lock.unlock()
        return empty
    }

    func processInput(connectionID: UUID, frames: Int) {
        lock.lock()

        guard let inputRoute = inputRoutes[connectionID] else {
            lock.unlock()
            return
        }

        if processingBuffer.count < frames {
            let newSize = max(frames, Int(channelCount) * 4096)
            processingBuffer = Array(repeating: 0, count: newSize)
        }

        let outputsSnapshot: [OutputRoute] = Array(outputRoutes.values)
        let chain = effectChain
        let readFrames = processingBuffer.withUnsafeMutableBufferPointer { ptr -> Int in
            guard let base = ptr.baseAddress else { return 0 }
            return inputRoute.ring.read(into: base, frames: frames)
        }

        lock.unlock()

        guard readFrames > 0 else { return }

        if let chain = chain {
            processingBuffer.withUnsafeMutableBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                chain.process(buffer: base, frameCount: readFrames)
            }
        }

        for route in outputsSnapshot {
            processingBuffer.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                route.ring.write(base, frames: readFrames)
            }
        }

        for route in outputsSnapshot {
            route.completion?(route.ring, readFrames)
        }
    }
}
