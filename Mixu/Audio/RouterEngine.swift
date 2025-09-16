import AVFoundation
import os.log

// MARK: - Orchestrator
class RouterEngine: ObservableObject {
    private let deviceManager = AudioDeviceManager()

    @Published var passThruName: String = "BlackHole 64ch" // ou "BlackHole 2ch"
    @Published var selectedOutputs: Set<String> = []    // UIDs des devices sélectionnés

    private var input: InputDevice?
    private var sinks: [String: OutputSink] = [:] // UID → sink

    // Shared ring buffer: ~100 ms @ 48kHz stéréo
    private let ring = AudioRingBuffer(capacityFrames: 4800, channels: 2)

    // Format interne fixé (celui du device virtuel)
    private var inFormat = StreamFormat.make(sampleRate: 48000, channels: 2)

    func availableOutputs() -> [AudioDevice] {
        deviceManager.allDevices().filter { $0.numOutputs > 0 && $0.name != passThruName }
    }
    
    func availableInputs() -> [AudioDevice] {
        deviceManager.allDevices().filter { $0.numInputs > 0 && $0.name != passThruName  }
    }

    func getPassThru() -> AudioDevice {
        deviceManager.findDevice(byName: passThruName)!
    }

    func start() {
        guard let inDev = deviceManager.findDevice(byName: passThruName),
              inDev.numInputs > 0 && inDev.numOutputs > 0 else {
            os_log("Input virtual device not found", log: log, type: .fault)
            return
        }
        // Configure input
        do {
            input = try InputDevice(deviceID: inDev.id, format: inFormat, ring: ring)
            input?.start()
        } catch {
            os_log("Failed to start input: %{public}@", log: log, type: .fault, String(describing: error))
        }

        // Start currently selected outputs
        for dev in availableOutputs() where selectedOutputs.contains(dev.uid) {
            addOutput(device: dev)
        }
    }

    func stop() {
        input?.stop(); input = nil
        sinks.values.forEach { $0.stop() }
        sinks.removeAll()
    }

    func toggleOutput(_ device: AudioDevice, enabled: Bool) {
        if enabled {
            guard let resolvedID = AudioDeviceManager().deviceID(forUID: device.uid) else {
                print("❌ Could not resolve AudioDeviceID for \(device.name)")
                return
            }
            print("✅ Binding output to \(device.name) with id=\(resolvedID)")

            let outFormat = StreamFormat.make(sampleRate: 48000, channels: 2)
            let sink = try? OutputSink(deviceID: resolvedID,
                                       inFormat: inFormat,
                                       outFormat: outFormat,
                                       ring: ring)
            sinks[device.uid] = sink
            sink?.start()
        } else {
            sinks[device.uid]?.stop()
            sinks[device.uid] = nil
        }
    }

    private func addOutput(device: AudioDevice) {
        guard sinks[device.uid] == nil else { return }
        let outFormat = StreamFormat.make(sampleRate: 48000, channels: 2)
        do {
            let sink = try OutputSink(deviceID: device.id,
                                      inFormat: inFormat,
                                      outFormat: outFormat,
                                      ring: ring)
            sinks[device.uid] = sink
            sink.start()
        } catch {
            os_log("Failed to start sink: %{public}@", log: log, type: .error, String(describing: error))
        }
    }

    private func removeOutput(uid: String) {
        if let s = sinks.removeValue(forKey: uid) { s.stop() }
    }
}
