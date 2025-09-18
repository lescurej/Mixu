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

// MARK: - Enhanced Router Engine
class RouterEngine: ObservableObject {
    private let deviceManager = AudioDeviceManager()
    
    @Published var passThruName: String = "BlackHole 64ch"
    @Published var selectedOutputs: Set<String> = []
    @Published var audioConnections: [AudioConnection] = []
    
    private var inputs: [String: InputDevice] = [:]  // UID → input device
    private var sinks: [String: OutputSink] = [:]    // UID → output sink
    private var rings: [String: AudioRingBuffer] = [:] // Connection ID → ring buffer
    
    private var inFormat = StreamFormat.make(sampleRate: 48000, channels: 2)
    
    func availableOutputs() -> [AudioDevice] {
        deviceManager.allDevices().filter { $0.numOutputs > 0 }
    }
    
    func availableInputs() -> [AudioDevice] {
        deviceManager.allDevices().filter { $0.numInputs > 0 }
    }
    
    func getPassThru() -> AudioDevice {
        deviceManager.findDevice(byName: passThruName)!
    }
    
    // MARK: - Connection Management
    func createAudioConnection(id: UUID, fromDeviceUID: String, fromPort: Int, toDeviceUID: String, toPort: Int) {
        print("Creating audio connection:")
        print("  From UID: \(fromDeviceUID)")
        print("  To UID: \(toDeviceUID)")
        
        // Debug: List all available device UIDs
        print("Available input devices:")
        for device in availableInputs() {
            print("  - \(device.name): \(device.uid)")
        }
        print("Available output devices:")
        for device in availableOutputs() {
            print("  - \(device.name): \(device.uid)")
        }
        
        let connection = AudioConnection(
            id: id,
            fromDeviceUID: fromDeviceUID,
            fromPortIndex: fromPort,
            toDeviceUID: toDeviceUID,
            toPortIndex: toPort
        )
        
        audioConnections.append(connection)
        setupAudioRouting(for: connection)
    }
    
    func removeAudioConnection(id: UUID) {
        audioConnections.removeAll { $0.id == id }
        teardownAudioRouting(for: id)
    }
    
    // Update the setupAudioRouting method to always use real devices
    private func setupAudioRouting(for connection: AudioConnection) {
        // Create dedicated ring buffer for this connection
        let ring = AudioRingBuffer(capacityFrames: 4800, channels: 2)
        rings[connection.id.uuidString] = ring
        
        // Always try to use real device input first
        if let inputDevice = availableInputs().first(where: { $0.uid == connection.fromDeviceUID }) {
            print("🎤 Setting up real input device: \(inputDevice.name)")
            setupInputDevice(uid: connection.fromDeviceUID, ring: ring)
        } else {
            // Fall back to test tone only if device not found
            print("⚠️ Input device not found, using test tone generator")
            setupTestToneGenerator(uid: connection.fromDeviceUID, ring: ring)
        }
        
        // Setup output device
        if let outputDevice = availableOutputs().first(where: { $0.uid == connection.toDeviceUID }) {
            print("🔊 Setting up real output device: \(outputDevice.name)")
            setupOutputDevice(uid: connection.toDeviceUID, ring: ring)
        } else {
            print("❌ Output device not found: \(connection.toDeviceUID)")
        }
    }
    
    private func setupTestToneGenerator(uid: String, ring: AudioRingBuffer) {
        // Create a test tone generator instead of a real input device
        print("🎵 Setting up test tone generator for \(uid)")
        
        do {
            // Use dummy device ID since we're not actually using it
            let dummyDeviceID: AudioDeviceID = 0
            let testTone = try InputDevice(deviceID: dummyDeviceID, format: inFormat, ring: ring)
            inputs[uid] = testTone
            testTone.start()
            print("🎵 Started test tone generator for \(uid)")
        } catch {
            print("❌ Failed to start test tone generator: \(error)")
        }
    }
    
    private func setupInputDevice(uid: String, ring: AudioRingBuffer) {
        guard inputs[uid] == nil else { return }
        
        guard let device = deviceManager.allDevices().first(where: { $0.uid == uid }),
              let deviceID = deviceManager.deviceID(forUID: uid) else {
            print("❌ Input device not found: \(uid)")
            return
        }
        
        // Only set up input devices that actually have inputs
        guard device.numInputs > 0 else {
            print("❌ Device has no inputs: \(device.name)")
            return
        }
        
        do {
            let input = try InputDevice(deviceID: deviceID, format: inFormat, ring: ring)
            inputs[uid] = input
            input.start()
            print("✅ Started input device: \(device.name)")
        } catch {
            print("❌ Failed to start input \(device.name): \(error)")
        }
    }
    
    private func setupOutputDevice(uid: String, ring: AudioRingBuffer) {
        guard sinks[uid] == nil else { return }
        
        guard let device = deviceManager.allDevices().first(where: { $0.uid == uid }),
              let deviceID = deviceManager.deviceID(forUID: uid) else {
            print("❌ Output device not found: \(uid)")
            return
        }
        
        // Only set up output devices that actually have outputs
        guard device.numOutputs > 0 else {
            print("❌ Device has no outputs: \(device.name)")
            return
        }
        
        do {
            let outFormat = StreamFormat.make(sampleRate: 48000, channels: 2)
            let sink = try OutputSink(deviceID: deviceID, inFormat: inFormat, outFormat: outFormat, ring: ring)
            sinks[uid] = sink
            sink.start()
            print("✅ Started output device: \(device.name)")
        } catch {
            print("❌ Failed to start output \(device.name): \(error)")
        }
    }
    
    private func teardownAudioRouting(for connectionId: UUID) {
        let connectionIdString = connectionId.uuidString
        rings.removeValue(forKey: connectionIdString)
        
        // Clean up unused inputs and outputs
        cleanupUnusedDevices()
    }
    
    private func cleanupUnusedDevices() {
        let usedInputUIDs = Set(audioConnections.map { $0.fromDeviceUID })
        let usedOutputUIDs = Set(audioConnections.map { $0.toDeviceUID })
        
        // Remove unused inputs
        for (uid, input) in inputs {
            if !usedInputUIDs.contains(uid) {
                input.stop()
                inputs.removeValue(forKey: uid)
            }
        }
        
        // Remove unused outputs
        for (uid, sink) in sinks {
            if !usedOutputUIDs.contains(uid) {
                sink.stop()
                sinks.removeValue(forKey: uid)
            }
        }
    }
    
    // MARK: - Legacy methods (keep for compatibility)
    func start() {
        // Legacy start - now connections are managed individually
    }
    
    func stop() {
        // Stop all audio devices
        inputs.values.forEach { $0.stop() }
        sinks.values.forEach { $0.stop() }
        inputs.removeAll()
        sinks.removeAll()
        rings.removeAll()
        audioConnections.removeAll()
    }
    
    func toggleOutput(_ device: AudioDevice, enabled: Bool) {
        // Legacy method - kept for compatibility
        if enabled {
            selectedOutputs.insert(device.uid)
        } else {
            selectedOutputs.remove(device.uid)
        }
    }
}
