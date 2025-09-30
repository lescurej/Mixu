import AVFoundation
import CoreAudio
import os.log

// MARK: - Audio Graph
enum ConnectionEndpoint: Equatable {
    case device(uid: String, deviceID: AudioDeviceID)
    case plugin(id: UUID)
}

struct AudioConnection {
    let id: UUID
    let fromPort: Port
    let toPort: Port
    let fromEndpoint: ConnectionEndpoint
    let toEndpoint: ConnectionEndpoint
    let channelOffset: Int  // Which BlackHole channel to start from
    var effects: [AudioPluginDescriptor]
}

struct PluginNodeInfo: Identifiable {
    let id: UUID
    let name: String
    let channelCount: Int
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
    private var plugins: [UUID: PluginNode] = [:]
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
            connectionInvolvesDevice(connection, deviceID: deviceID)
        }
        
        if isConnected {
            refreshCanonicalFormat()
            updateConnectedDevices()
        }
    }

    private func connectionInvolvesDevice(_ connection: AudioConnection, deviceID: AudioDeviceID) -> Bool {
        switch connection.fromEndpoint {
        case .device(_, let id) where id == deviceID:
            return true
        default:
            break
        }

        switch connection.toEndpoint {
        case .device(_, let id) where id == deviceID:
            return true
        default:
            break
        }

        return false
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
                    toPort: connection.toPort,
                    effects: connection.effects
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

    func availableAudioUnitEffects(includeMusicEffects: Bool = false) -> [AudioPluginDescriptor] {
        var descriptors: [AudioPluginDescriptor] = []
        var componentTypes: [OSType] = [kAudioUnitType_Effect]
        if includeMusicEffects {
            componentTypes.append(kAudioUnitType_MusicEffect)
        }

        for type in componentTypes {
            var searchDescription = AudioComponentDescription(
                componentType: type,
                componentSubType: 0,
                componentManufacturer: 0,
                componentFlags: 0,
                componentFlagsMask: 0
            )

            var component = AudioComponentFindNext(nil, &searchDescription)
            while let current = component {
                var actualDescription = AudioComponentDescription()
                let descriptionStatus = AudioComponentGetDescription(current, &actualDescription)
                if descriptionStatus == noErr {
                    var unmanagedName: Unmanaged<CFString>?
                    let nameStatus = AudioComponentCopyName(current, &unmanagedName)
                    let nameString: String
                    if nameStatus == noErr, let value = unmanagedName?.takeRetainedValue() {
                        nameString = value as String
                    } else {
                        nameString = "Audio Unit"
                    }

                    let descriptor = AudioPluginDescriptor(name: nameString, audioUnitDescription: actualDescription)
                    descriptors.append(descriptor)
                }

                component = AudioComponentFindNext(current, &searchDescription)
            }
        }

        return descriptors
    }

    private func ensureCanonicalChannelCount(_ requested: Int) {
        guard requested > Int(canonicalFormat.channelCount) else { return }
        let oldFormat = canonicalFormat
        canonicalFormat = StreamFormat.make(sampleRate: canonicalFormat.sampleRate,
                                            channels: UInt32(requested))
        updateExistingDevicesForNewFormat(oldFormat: oldFormat, newFormat: canonicalFormat)
        for plugin in plugins.values {
            plugin.reinitializeChain(with: canonicalFormat)
        }
    }

    func createPluginNode(descriptor: AudioPluginDescriptor, channelCount: Int) throws -> PluginNodeInfo {
        ensureCanonicalChannelCount(channelCount)

        let pluginID = UUID()
        let plugin = PluginNode(id: pluginID, descriptor: descriptor, format: canonicalFormat)
        plugins[pluginID] = plugin

        return PluginNodeInfo(id: pluginID,
                              name: descriptor.name,
                              channelCount: Int(canonicalFormat.channelCount))
    }

    func removePluginNode(id: UUID) {
        guard plugins[id] != nil else { return }

        let pluginEndpoint = ConnectionEndpoint.plugin(id: id)
        let affectedConnections = audioConnections.filter {
            $0.fromEndpoint == pluginEndpoint || $0.toEndpoint == pluginEndpoint
        }

        for connection in affectedConnections {
            removeAudioConnection(id: connection.id)
        }

        plugins[id]?.removeAllRoutes()
        plugins.removeValue(forKey: id)
    }

    func pluginNodesSnapshot() -> [PluginNodeInfo] {
        plugins.map { (key, node) in
            PluginNodeInfo(id: key,
                           name: node.descriptor.name,
                           channelCount: Int(node.channelCount))
        }
    }

    // MARK: - Connection Management
    func createAudioConnection(id: UUID, fromPort: Port, toPort: Port, effects: [AudioPluginDescriptor] = []) throws {
        let fromEndpoint = try endpoint(for: fromPort)
        let toEndpoint = try endpoint(for: toPort)
        guard !fromPort.isInput && toPort.isInput else {
            throw AudioError.invalidConnection
        }
        let channelOffset = toPort.index

        let connection = AudioConnection(
            id: id,
            fromPort: fromPort,
            toPort: toPort,
            fromEndpoint: fromEndpoint,
            toEndpoint: toEndpoint,
            channelOffset: channelOffset,
            effects: effects
        )

        let ring = AudioRingBuffer(capacityFrames: 4096)

        switch (fromEndpoint, toEndpoint) {
        case let (.device(fromUID, fromDeviceID), .device(toUID, toDeviceID)):
            try setupDeviceToDeviceConnection(connection: connection,
                                              ring: ring,
                                              fromPort: fromPort,
                                              toPort: toPort,
                                              fromUID: fromUID,
                                              fromDeviceID: fromDeviceID,
                                              toUID: toUID,
                                              toDeviceID: toDeviceID)

        case let (.device(fromUID, fromDeviceID), .plugin(pluginID)):
            try setupDeviceToPluginConnection(connection: connection,
                                             ring: ring,
                                             fromPort: fromPort,
                                             pluginID: pluginID,
                                             deviceUID: fromUID,
                                             deviceID: fromDeviceID)

        case let (.plugin(pluginID), .device(toUID, toDeviceID)):
            try setupPluginToDeviceConnection(connection: connection,
                                             ring: ring,
                                             pluginID: pluginID,
                                             toPort: toPort,
                                             deviceUID: toUID,
                                             deviceID: toDeviceID)

        case let (.plugin(fromPluginID), .plugin(toPluginID)):
            try setupPluginToPluginConnection(connection: connection,
                                             ring: ring,
                                             fromPluginID: fromPluginID,
                                             toPluginID: toPluginID)
        }

        rings[id] = ring
        audioConnections.append(connection)
    }

    private func endpoint(for port: Port) throws -> ConnectionEndpoint {
        if let pluginID = port.pluginID {
            guard plugins[pluginID] != nil else {
                throw AudioError.pluginNotFound
            }
            return .plugin(id: pluginID)
        }

        guard let device = port.device else {
            throw AudioError.deviceNotFound
        }

        return .device(uid: device.uid, deviceID: device.id)
    }

    private func setupDeviceToDeviceConnection(
        connection: AudioConnection,
        ring: AudioRingBuffer,
        fromPort: Port,
        toPort: Port,
        fromUID: String,
        fromDeviceID: AudioDeviceID,
        toUID: String,
        toDeviceID: AudioDeviceID
    ) throws {
        deviceManager.addDeviceChangeListener(for: fromDeviceID)
        deviceManager.addDeviceChangeListener(for: toDeviceID)

        guard let fromDeviceFormat = deviceManager.streamFormat(deviceID: fromDeviceID, scope: .input),
              let toDeviceFormat = deviceManager.streamFormat(deviceID: toDeviceID, scope: .output) else {
            throw AudioError.deviceFormatUnavailable
        }

        let internalFormat = canonicalFormat

        let source: AudioSource
        if let existingSource = sources[fromUID] {
            source = existingSource
        } else {
            let newSource = try AudioSource(
                uid: fromUID,
                deviceID: fromDeviceID,
                deviceFormat: fromDeviceFormat,
                internalFormat: internalFormat
            )
            sources[fromUID] = newSource
            source = newSource
        }

        let destinationKey = DestinationKey(deviceUID: toUID, channelOffset: connection.channelOffset)
        let destination: AudioDestination
        let isNewDestination: Bool
        if let existingDestination = destinations[destinationKey] {
            destination = existingDestination
            isNewDestination = false
        } else {
            let newDestination = try AudioDestination(
                uid: toUID,
                deviceID: toDeviceID,
                deviceFormat: toDeviceFormat,
                internalFormat: internalFormat,
                channelOffset: connection.channelOffset
            )
            destinations[destinationKey] = newDestination
            destination = newDestination
            isNewDestination = true
        }

        source.addRoute(id: connection.id, ring: ring, channelOffset: fromPort.index, completion: nil)
        destination.addRoute(id: connection.id, ring: ring, effects: connection.effects)

        source.start()
        if isNewDestination {
            destination.start()
        }
    }

    private func setupDeviceToPluginConnection(connection: AudioConnection,
                                                ring: AudioRingBuffer,
                                                fromPort: Port,
                                                pluginID: UUID,
                                                deviceUID: String,
                                                deviceID: AudioDeviceID) throws {
        guard fromPort.device != nil else {
            throw AudioError.deviceNotFound
        }

        guard let plugin = plugins[pluginID] else {
            throw AudioError.pluginNotFound
        }

        deviceManager.addDeviceChangeListener(for: deviceID)

        guard let fromDeviceFormat = deviceManager.streamFormat(deviceID: deviceID, scope: .input) else {
            throw AudioError.deviceFormatUnavailable
        }

        let internalFormat = canonicalFormat

        let source: AudioSource
        if let existingSource = sources[deviceUID] {
            source = existingSource
        } else {
            let newSource = try AudioSource(
                uid: deviceUID,
                deviceID: deviceID,
                deviceFormat: fromDeviceFormat,
                internalFormat: internalFormat
            )
            sources[deviceUID] = newSource
            source = newSource
        }

        plugin.addInputRoute(connectionID: connection.id, ring: ring)

        source.addRoute(id: connection.id, ring: ring, channelOffset: fromPort.index) { [weak plugin] ring, frames in
            plugin?.processInput(connectionID: connection.id, frames: frames)
        }

        source.start()
    }

    private func setupPluginToDeviceConnection(connection: AudioConnection,
                                                ring: AudioRingBuffer,
                                                pluginID: UUID,
                                                toPort: Port,
                                                deviceUID: String,
                                                deviceID: AudioDeviceID) throws {
        guard let plugin = plugins[pluginID] else {
            throw AudioError.pluginNotFound
        }

        guard toPort.device != nil else {
            throw AudioError.deviceNotFound
        }

        deviceManager.addDeviceChangeListener(for: deviceID)

        guard let toDeviceFormat = deviceManager.streamFormat(deviceID: deviceID, scope: .output) else {
            throw AudioError.deviceFormatUnavailable
        }

        let internalFormat = canonicalFormat

        let destinationKey = DestinationKey(deviceUID: deviceUID, channelOffset: connection.channelOffset)
        let destination: AudioDestination
        let isNewDestination: Bool
        if let existingDestination = destinations[destinationKey] {
            destination = existingDestination
            isNewDestination = false
        } else {
            let newDestination = try AudioDestination(
                uid: deviceUID,
                deviceID: deviceID,
                deviceFormat: toDeviceFormat,
                internalFormat: internalFormat,
                channelOffset: connection.channelOffset
            )
            destinations[destinationKey] = newDestination
            destination = newDestination
            isNewDestination = true
        }

        plugin.addOutputRoute(connectionID: connection.id, ring: ring, completion: nil)
        destination.addRoute(id: connection.id, ring: ring, effects: connection.effects)

        if isNewDestination {
            destination.start()
        }
    }

    private func setupPluginToPluginConnection(connection: AudioConnection,
                                                ring: AudioRingBuffer,
                                                fromPluginID: UUID,
                                                toPluginID: UUID) throws {
        guard let sourcePlugin = plugins[fromPluginID], let destinationPlugin = plugins[toPluginID] else {
            throw AudioError.pluginNotFound
        }

        destinationPlugin.addInputRoute(connectionID: connection.id, ring: ring)

        sourcePlugin.addOutputRoute(connectionID: connection.id, ring: ring) { [weak destinationPlugin] _, frames in
            destinationPlugin?.processInput(connectionID: connection.id, frames: frames)
        }
    }

    func removeAudioConnection(id: UUID) {
        guard let index = audioConnections.firstIndex(where: { $0.id == id }) else { return }
        let connection = audioConnections.remove(at: index)
        
        if case let .device(_, fromDeviceID) = connection.fromEndpoint {
            let stillConnected = audioConnections.contains { connectionInvolvesDevice($0, deviceID: fromDeviceID) }
            if !stillConnected {
                deviceManager.removeDeviceChangeListener(for: fromDeviceID)
            }
        }

        if case let .device(_, toDeviceID) = connection.toEndpoint {
            let stillConnected = audioConnections.contains { connectionInvolvesDevice($0, deviceID: toDeviceID) }
            if !stillConnected {
                deviceManager.removeDeviceChangeListener(for: toDeviceID)
            }
        }

        teardownAudioRouting(for: connection)
    }

    func setEffects(_ descriptors: [AudioPluginDescriptor], for connectionId: UUID) {
        guard let index = audioConnections.firstIndex(where: { $0.id == connectionId }) else {
            print("Warning: Connection not found for effects update: \(connectionId)")
            return
        }

        audioConnections[index].effects = descriptors
        let connection = audioConnections[index]
        if case let .device(deviceUID, _) = connection.toEndpoint {
            let destinationKey = DestinationKey(deviceUID: deviceUID, channelOffset: connection.channelOffset)
            if let destination = destinations[destinationKey] {
                destination.setEffects(for: connectionId, descriptors: descriptors)
            } else {
                print("Warning: Destination not available for effects update on connection \(connectionId)")
            }
        }
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

        for plugin in plugins.values {
            plugin.removeAllRoutes()
        }
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
        let channels = max(1, canonicalFormat.channelCount)
        canonicalFormat = StreamFormat.make(sampleRate: newSampleRate, channels: UInt32(channels))
        
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
                        newSource.addRoute(id: routeId,
                                           ring: route.ring,
                                           channelOffset: route.channelOffset,
                                           completion: route.completion)
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

                for (routeId, ring, descriptors) in destination.routesSnapshot() {
                    newDestination.addRoute(id: routeId, ring: ring, effects: descriptors)
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

        for plugin in plugins.values {
            plugin.reinitializeChain(with: newFormat)
        }
    }

    private func refreshCanonicalFormat() {
        // Find the maximum sample rate from currently connected devices only
        var maxSampleRate: Double = 48000.0 // Default fallback
        
        // Get all devices that are currently in use
        var connectedDevices: Set<AudioDevice> = []
        for connection in audioConnections {
            if let device = connection.fromPort.device {
                connectedDevices.insert(device)
            }
            if let device = connection.toPort.device {
                connectedDevices.insert(device)
            }
        }
        
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
        
        switch connection.fromEndpoint {
        case let .device(uid, _):
            if let source = sources[uid] {
                print("🔧 teardownAudioRouting: Removing source route")
                let hasRoutes = source.removeRoute(id: connection.id)
                print("🔧 teardownAudioRouting: Source has routes: \(hasRoutes)")
                if !hasRoutes {
                    print("🔧 teardownAudioRouting: Stopping source")
                    source.stop()
                    print("🔧 teardownAudioRouting: Removing source from dictionary")
                    sources.removeValue(forKey: uid)
                }
            }
        case let .plugin(pluginID):
            plugins[pluginID]?.removeOutputRoute(connectionID: connection.id)
        }

        switch connection.toEndpoint {
        case let .device(uid, _):
            let destinationKey = DestinationKey(deviceUID: uid, channelOffset: connection.channelOffset)
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
        case let .plugin(pluginID):
            plugins[pluginID]?.removeInputRoute(connectionID: connection.id)
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
    case pluginNotFound
    case invalidConnection
}
