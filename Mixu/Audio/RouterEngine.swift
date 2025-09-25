import AVFoundation
import CoreAudio
import os.log

// MARK: - Audio Connection
struct AudioConnection {
    let id: UUID
    let fromPort: Port
    let toPort: Port
    let channelOffset: Int  // Which BlackHole channel to start from
}

// MARK: - Router Engine
class RouterEngine: ObservableObject {
    private struct DestinationKey: Hashable {
        let deviceUID: String
        let channelOffset: Int
    }

    private let deviceManager = AudioDeviceManager()
    private var deviceChangeObserver: NSObjectProtocol?

    @Published var passThruName: String = "BlackHole 64ch" {
        didSet { refreshCanonicalFormat() }
    }
    @Published var selectedOutputs: Set<String> = []
    @Published var audioConnections: [AudioConnection] = []

    private var sources: [String: AudioSource] = [:]
    private var destinations: [DestinationKey: AudioDestination] = [:]
    private var rings: [UUID: AudioRingBuffer] = [:]

    private var canonicalFormat = StreamFormat.make(sampleRate: 48_000, channels: 1) // 1 channel internal format

    init() {
        refreshCanonicalFormat()
        setupDeviceChangeObserver()
    }
    
    deinit {
        removeDeviceChangeObserver()
    }
    
    private func setupDeviceChangeObserver() {
        deviceChangeObserver = NotificationCenter.default.addObserver(
            forName: .audioDeviceFormatChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleDeviceFormatChange(notification)
        }
    }
    
    private func removeDeviceChangeObserver() {
        if let observer = deviceChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func handleDeviceFormatChange(_ notification: Notification) {
        guard let deviceID = notification.userInfo?["deviceID"] as? AudioObjectID else { return }
        
        // Check if this device is currently connected
        let isConnected = audioConnections.contains { connection in
            connection.fromPort.device.id == deviceID || connection.toPort.device.id == deviceID
        }
        
        if isConnected {
            refreshCanonicalFormat()
            updateConnectedDevices()
        }
    }
    
    private func updateConnectedDevices() {
        // Recreate all sources and destinations with new formats
        let currentConnections = audioConnections
        
        // Stop all current audio
        stop()
        
        // Recreate connections with updated formats
        for connection in currentConnections {
            do {
                try createAudioConnection(
                    id: connection.id,
                    fromPort: connection.fromPort,
                    toPort: connection.toPort
                )
            } catch {
                print("Failed to recreate connection \(connection.id) after format change: \(error)")
                // Continue with other connections even if one fails
            }
        }
    }

    func availableOutputs() -> [AudioDevice] {
        deviceManager.allDevices().filter { $0.numOutputs > 0 && !$0.name.contains(passThruName) }
    }

    func availableInputs() -> [AudioDevice] {
        deviceManager.allDevices().filter { $0.numInputs > 0 && !$0.name.contains(passThruName) }
    }

    func passThruDevice() -> AudioDevice? {
        deviceManager.findDevice(byName: passThruName)
    }

    // MARK: - Connection Management
    func createAudioConnection(id: UUID, fromPort: Port, toPort: Port) throws {
        // Use the destination port's index as the channel offset
        let channelOffset = toPort.index
        
        let connection = AudioConnection(
            id: id,
            fromPort: fromPort,
            toPort: toPort,
            channelOffset: channelOffset
        )

        deviceManager.addDeviceChangeListener(for: fromPort.device.id)
        deviceManager.addDeviceChangeListener(for: toPort.device.id)

        guard let fromDeviceFormat = deviceManager.streamFormat(deviceID: fromPort.device.id, scope: .input),
              let toDeviceFormat = deviceManager.streamFormat(deviceID: toPort.device.id, scope: .output) else {
            throw AudioError.deviceFormatUnavailable
        }

        print("�� Device Formats:")
        print("  From device (\(fromPort.device.name)): \(fromDeviceFormat.debugDescription)")
        print("  To device (\(toPort.device.name)): \(toDeviceFormat.debugDescription)")

        // Check if formats are valid
        guard fromDeviceFormat.isValid && toDeviceFormat.isValid else {
            print("❌ Invalid device formats detected")
            throw AudioError.deviceFormatUnavailable
        }

        // Debug: Print the actual ASBD values
        print(" ASBD Details:")
        print("  From device ASBD: sampleRate=\(fromDeviceFormat.sampleRate), channels=\(fromDeviceFormat.channelCount), formatID=\(fromDeviceFormat.asbd.mFormatID)")
        print("  To device ASBD: sampleRate=\(toDeviceFormat.sampleRate), channels=\(toDeviceFormat.channelCount), formatID=\(toDeviceFormat.asbd.mFormatID)")

        let internalFormat = StreamFormat.make(sampleRate: 48000, channels: 1)

        // Create ring buffer for this connection
        let ring = AudioRingBuffer(capacityFrames: 4096)

        // Create or reuse the source for this device
        let source: AudioSource
        if let existingSource = sources[fromPort.device.uid] {
            source = existingSource
        } else {
            let newSource = try AudioSource(
                uid: fromPort.device.uid,
                deviceID: fromPort.device.id,
                deviceFormat: fromDeviceFormat,
                internalFormat: internalFormat
            )
            sources[fromPort.device.uid] = newSource
            source = newSource
        }

        print("🔍 Preparing AudioDestination with:")
        print("  deviceID: \(toPort.device.id)")
        print("  deviceFormat: \(toDeviceFormat.debugDescription)")
        print("  internalFormat: \(internalFormat.debugDescription)")
        print("  channelOffset: \(channelOffset)")

        let destinationKey = DestinationKey(deviceUID: toPort.device.uid, channelOffset: channelOffset)
        let destination: AudioDestination
        let isNewDestination: Bool
        if let existingDestination = destinations[destinationKey] {
            destination = existingDestination
            isNewDestination = false
        } else {
            let newDestination = try AudioDestination(
                uid: toPort.device.uid,
                deviceID: toPort.device.id,
                deviceFormat: toDeviceFormat,
                internalFormat: internalFormat,
                channelOffset: channelOffset
            )
            destinations[destinationKey] = newDestination
            destination = newDestination
            isNewDestination = true
        }

        // Connect them via the ring buffer
        source.addRoute(id: id, ring: ring, channelOffset: fromPort.index)
        destination.addRoute(id: id, ring: ring)

        // Keep track of route components
        rings[id] = ring

        // Start the audio components
        source.start()
        if isNewDestination {
            destination.start()
        }

        audioConnections.append(connection)
    }

    func removeAudioConnection(id: UUID) {
        guard let index = audioConnections.firstIndex(where: { $0.id == id }) else { return }
        let connection = audioConnections.remove(at: index)
        
        // Check if we need to remove listeners for devices that are no longer connected
        let fromDeviceID = connection.fromPort.device.id
        let toDeviceID = connection.toPort.device.id
        
        // Remove listener for fromDevice if no longer connected
        let fromDeviceStillConnected = audioConnections.contains { conn in
            conn.fromPort.device.id == fromDeviceID || conn.toPort.device.id == fromDeviceID
        }
        if !fromDeviceStillConnected {
            deviceManager.removeDeviceChangeListener(for: fromDeviceID)
        }
        
        // Remove listener for toDevice if no longer connected
        let toDeviceStillConnected = audioConnections.contains { conn in
            conn.fromPort.device.id == toDeviceID || conn.toPort.device.id == toDeviceID
        }
        if !toDeviceStillConnected {
            deviceManager.removeDeviceChangeListener(for: toDeviceID)
        }
        
        teardownAudioRouting(for: connection)
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
    func updateInternalFormat(to newSampleRate: Double) {
        let oldFormat = canonicalFormat
        canonicalFormat = StreamFormat.make(sampleRate: newSampleRate, channels: 1)
        
        print("Internal format updated: sampleRate=\(canonicalFormat.sampleRate), channels=\(canonicalFormat.channelCount)")
        
        // Update all existing sources and destinations to use the new internal format
        updateExistingDevicesForNewFormat(oldFormat: oldFormat, newFormat: canonicalFormat)
    }
    
    func updateExistingDevicesForNewFormat(oldFormat: StreamFormat, newFormat: StreamFormat) {
        // Update all existing sources
        for (uid, source) in sources {
            if let deviceID = deviceManager.deviceID(forUID: uid),
               let deviceFormat = deviceManager.streamFormat(deviceID: deviceID, scope: .input) {
                
                // Create new source with updated internal format
                do {
                    let newSource = try AudioSource(
                        uid: uid,
                        deviceID: deviceID,
                        deviceFormat: deviceFormat,
                        internalFormat: newFormat
                    )
                    
                    // Transfer existing routes
                    for (routeId, route) in source.routes {
                        newSource.addRoute(id: routeId, ring: route.ring, channelOffset: route.channelOffset)
                    }
                    
                    // Stop old source and start new one
                    source.stop()
                    sources[uid] = newSource
                    newSource.start()
                    
                    print("Updated source \(uid) to new internal format")
                } catch {
                    print("Warning: Failed to update source \(uid): \(error)")
                    // Continue with other sources even if one fails
                }
            }
        }
        
        // Update all existing destinations
        for key in Array(destinations.keys) {
            guard let destination = destinations[key] else { continue }

            guard let deviceID = deviceManager.deviceID(forUID: key.deviceUID) else {
                print("Warning: Destination device not found for UID \(key.deviceUID)")
                continue
            }

            guard let deviceFormat = deviceManager.streamFormat(deviceID: deviceID, scope: .output) else {
                print("Warning: Invalid output format for device \(key.deviceUID)")
                continue
            }

            do {
                let newDestination = try AudioDestination(
                    uid: key.deviceUID,
                    deviceID: deviceID,
                    deviceFormat: deviceFormat,
                    internalFormat: newFormat,
                    channelOffset: key.channelOffset
                )

                for (routeId, ring) in destination.routes {
                    newDestination.addRoute(id: routeId, ring: ring)
                }

                destination.stop()
                destinations[key] = newDestination
                newDestination.start()

                print("Updated destination for uid \(key.deviceUID) offset \(key.channelOffset) to new internal format")
            } catch {
                print("Warning: Failed to update destination for uid \(key.deviceUID) offset \(key.channelOffset): \(error)")
                // Continue with other destinations even if one fails
            }
        }
    }

    private func refreshCanonicalFormat() {
        // Find the maximum sample rate from currently connected devices only
        var maxSampleRate: Double = 48000.0 // Default fallback
        
        // Get all devices that are currently in use
        let connectedDevices = Set(audioConnections.flatMap { [$0.fromPort.device, $0.toPort.device] })
        
        // Check only connected devices for their sample rates
        for device in connectedDevices {
            if let inputFormat = deviceManager.streamFormat(deviceID: device.id, scope: .input) {
                maxSampleRate = max(maxSampleRate, inputFormat.sampleRate)
            }
            if let outputFormat = deviceManager.streamFormat(deviceID: device.id, scope: .output) {
                maxSampleRate = max(maxSampleRate, outputFormat.sampleRate)
            }
        }
        
        // If no connections yet, use default
        if connectedDevices.isEmpty {
            maxSampleRate = 48000.0
        }
        
        // Create internal format: 32-bit float, 1 channel, max sample rate from connected devices
        canonicalFormat = StreamFormat.make(sampleRate: maxSampleRate, channels: 1)
        print("Internal format set to: sampleRate=\(canonicalFormat.sampleRate), channels=\(canonicalFormat.channelCount) (based on \(connectedDevices.count) connected devices)")
    }

    func ensureSource(uid: String) -> AudioSource? {
        if let existing = sources[uid] { return existing }

        guard let deviceID = deviceManager.deviceID(forUID: uid) else {
            print("Warning: No device found for uid \(uid)")
            return nil
        }

        do {
            guard let detectedFormat = deviceManager.streamFormat(deviceID: deviceID, scope: .input), 
                  detectedFormat.sampleRate > 0, 
                  detectedFormat.channelCount > 0 else {
                print("Warning: Invalid input format for device \(uid) - sampleRate: \(deviceManager.streamFormat(deviceID: deviceID, scope: .input)?.sampleRate ?? 0), channels: \(deviceManager.streamFormat(deviceID: deviceID, scope: .input)?.channelCount ?? 0)")
                return nil
            }
            
            // Use the canonical format (1 channel, max sample rate) for internal processing
            let source = try AudioSource(
                uid: uid,
                deviceID: deviceID,
                deviceFormat: detectedFormat,
                internalFormat: canonicalFormat
            )
            sources[uid] = source
            print("Successfully created source for \(uid)")
            return source
        } catch {
            print("Error: Source creation failed for \(uid): \(error)")
            return nil
        }
    }

    private func teardownAudioRouting(for connection: AudioConnection) {
        print("🔧 teardownAudioRouting: Starting teardown for connection \(connection.id)")
        
        // Remove from sources
        if let source = sources[connection.fromPort.device.uid] {
            print("🔧 teardownAudioRouting: Removing source route")
            let hasRoutes = source.removeRoute(id: connection.id)
            print("🔧 teardownAudioRouting: Source has routes: \(hasRoutes)")
            
            if !hasRoutes {
                print("🔧 teardownAudioRouting: Stopping source")
                source.stop()
                print("🔧 teardownAudioRouting: Removing source from dictionary")
                sources.removeValue(forKey: connection.fromPort.device.uid)
            }
        }
        
        // Remove from destinations
        let destinationKey = DestinationKey(deviceUID: connection.toPort.device.uid, channelOffset: connection.channelOffset)
        if let destination = destinations[destinationKey] {
            print("🔧 teardownAudioRouting: Removing destination route")
            let hasRoutes = destination.removeRoute(id: connection.id)
            print("🔧 teardownAudioRouting: Destination has routes: \(hasRoutes)")

            if !hasRoutes {
                print("🔧 teardownAudioRouting: Stopping destination")
                destination.stop()
                print("🔧 teardownAudioRouting: Removing destination from dictionary")
                destinations.removeValue(forKey: destinationKey)
            }
        }
        
        // Remove ring buffer
        print("🔧 teardownAudioRouting: Removing ring buffer")
        rings.removeValue(forKey: connection.id)
        print("🔧 teardownAudioRouting: Teardown complete")
    }

    func releaseSource(uid: String) {
        guard let source = sources.removeValue(forKey: uid) else { return }
        source.stop()
    }

    func verifyBlackHoleInstallation() -> Bool {
        guard let passthru = passThruDevice() else {
            print("Error: BlackHole device not found. Please install BlackHole from: https://github.com/ExistentialAudio/BlackHole")
            return false
        }
        
        // Test if we can get a valid format
        guard let deviceID = deviceManager.deviceID(forUID: passthru.uid),
              let inputFormat = deviceManager.streamFormat(deviceID: deviceID, scope: .input),
              let outputFormat = deviceManager.streamFormat(deviceID: deviceID, scope: .output) else {
            print("Error: BlackHole device found but format detection failed")
            return false
        }
        
        print("Success: BlackHole verified - input=\(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch, output=\(outputFormat.sampleRate)Hz/\(outputFormat.channelCount)ch")
        return true
    }
}

enum AudioError: Error {
    case deviceFormatUnavailable
    case connectionFailed
    case deviceNotFound
}
