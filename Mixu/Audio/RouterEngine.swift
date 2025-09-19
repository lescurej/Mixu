import AVFoundation
import CoreAudio
import os.log

// MARK: - Audio Connection
struct AudioConnection {
    let id: UUID
    let fromDeviceUID: String
    let fromPortIndex: Int
    let toDeviceUID: String
    let toPortIndex: Int
}

// MARK: - Router Engine
class RouterEngine: ObservableObject {
    private let deviceManager = AudioDeviceManager()

    @Published var passThruName: String = "BlackHole 64ch"
    @Published var selectedOutputs: Set<String> = []
    @Published var audioConnections: [AudioConnection] = []

    private var sources: [String: AudioSource] = [:]
    private var destinations: [String: AudioDestination] = [:]
    private var rings: [UUID: AudioRingBuffer] = [:]

    private var canonicalFormat = StreamFormat.make(sampleRate: 48_000, channels: 2)

    func availableOutputs() -> [AudioDevice] {
        deviceManager.allDevices().filter { $0.numOutputs > 0 }
    }

    func availableInputs() -> [AudioDevice] {
        deviceManager.allDevices().filter { $0.numInputs > 0 }
    }

    func passThruDevice() -> AudioDevice? {
        deviceManager.findDevice(byName: passThruName)
    }

    // MARK: - Connection Management
    func createAudioConnection(id: UUID, fromDeviceUID: String, fromPort: Int, toDeviceUID: String, toPort: Int) {
        let connection = AudioConnection(
            id: id,
            fromDeviceUID: fromDeviceUID,
            fromPortIndex: fromPort,
            toDeviceUID: toDeviceUID,
            toPortIndex: toPort
        )

        let capacity = Int(canonicalFormat.sampleRate / 10.0)
        let ring = AudioRingBuffer(capacityFrames: max(1, capacity), channels: canonicalFormat.channelCount)

        guard let source = ensureSource(uid: fromDeviceUID) else {
            print("Failed to create source for UID \(fromDeviceUID)")
            return
        }

        guard let destination = ensureDestination(uid: toDeviceUID) else {
            print("Failed to create destination for UID \(toDeviceUID)")
            if !source.removeRoute(id: id) {
                releaseSource(uid: fromDeviceUID)
            }
            return
        }

        rings[id] = ring
        source.addRoute(id: id, ring: ring)
        destination.addRoute(id: id, ring: ring)

        source.start()
        destination.start()

        audioConnections.append(connection)
    }

    func removeAudioConnection(id: UUID) {
        guard let index = audioConnections.firstIndex(where: { $0.id == id }) else { return }
        let connection = audioConnections.remove(at: index)
        teardownAudioRouting(for: connection)
    }

    func start() {
        // Connections are started on demand.
    }

    func stop() {
        audioConnections.removeAll()
        rings.removeAll()

        for source in sources.values {
            source.stop()
        }
        sources.removeAll()

        for destination in destinations.values {
            destination.stop()
        }
        destinations.removeAll()
    }

    func toggleOutput(_ device: AudioDevice, enabled: Bool) {
        if enabled {
            selectedOutputs.insert(device.uid)
        } else {
            selectedOutputs.remove(device.uid)
        }
    }
}

// MARK: - Helpers
private extension RouterEngine {
    func ensureSource(uid: String) -> AudioSource? {
        if let existing = sources[uid] { return existing }

        guard let deviceID = deviceManager.deviceID(forUID: uid) else {
            // Fall back to a software generated tone for missing devices.
            do {
                let source = try AudioSource(uid: uid, deviceID: 0, format: canonicalFormat, useTestTone: true)
                sources[uid] = source
                return source
            } catch {
                print("Unable to create test tone source: \(error)")
                return nil
            }
        }

        do {
            let source = try AudioSource(uid: uid, deviceID: deviceID, format: canonicalFormat, useTestTone: false)
            sources[uid] = source
            return source
        } catch {
            print("Source creation failed for \(uid): \(error)")
            return nil
        }
    }

    func ensureDestination(uid: String) -> AudioDestination? {
        if let existing = destinations[uid] { return existing }

        // Validate device exists and is accessible
        guard deviceManager.validateDevice(uid: uid) else {
            print("❌ Device validation failed for \(uid)")
            return nil
        }

        guard let deviceID = deviceManager.deviceID(forUID: uid) else {
            print("Destination device not found for UID \(uid)")
            return nil
        }

        // Instead of using a fixed format, get the device's native format
        if let nativeFormat = deviceManager.getDeviceFormat(deviceID: deviceID) {
            
            print("Using native format for BlackHole device")
            do {
                let destination = try AudioDestination(uid: "BlackHole64ch_UID", deviceID: deviceID, format: nativeFormat)
                destinations[uid] = destination
                return destination
            } catch {
                print("Failed to create destination for \(uid): \(error)")
                return nil
            }
        } else {
            print("Failed to get device or format for BlackHole64ch_UID")
            return nil
        }
    }

    func teardownAudioRouting(for connection: AudioConnection) {
        rings.removeValue(forKey: connection.id)

        if let source = sources[connection.fromDeviceUID] {
            let stillInUse = source.removeRoute(id: connection.id)
            if !stillInUse {
                releaseSource(uid: connection.fromDeviceUID)
            }
        }

        if let destination = destinations[connection.toDeviceUID] {
            let stillInUse = destination.removeRoute(id: connection.id)
            if !stillInUse {
                releaseDestination(uid: connection.toDeviceUID)
            }
        }
    }

    func releaseSource(uid: String) {
        guard let source = sources.removeValue(forKey: uid) else { return }
        source.stop()
    }

    func releaseDestination(uid: String) {
        guard let destination = destinations.removeValue(forKey: uid) else { return }
        destination.stop()
    }
}
