import os.log
import SwiftUI

// MARK: - Logging
let log = OSLog(subsystem: "com.mixu.app", category: "audio")

// MARK: - Helpers (Check OSStatus)
@discardableResult
func check(_ status: OSStatus, _ message: String) -> OSStatus {
    if status != noErr {
        os_log("%{public}@ (status=%{public}d)", log: log, type: .error, message, status)
    }
    return status
}

struct ContentView: View {
    @StateObject var engine = RouterEngine()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack () {
                Text("Mixu").font(.title).bold()
            }
            Divider()
            PatchbayView(engine: engine)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
    }
}


final class MockRouterEngine: RouterEngine {
    override func availableInputs() -> [AudioDevice] {
        [.init(id: 1, name: "Built-in Mic", uid: "mic", numOutputs: 0, numInputs: 2),
         .init(id: 2, name: "Virtual Mic", uid: "vmic", numOutputs: 0, numInputs: 4)]
    }
    override func availableOutputs() -> [AudioDevice] {
        [.init(id: 3, name: "Speakers", uid: "spk", numOutputs: 2, numInputs: 0),
         .init(id: 4, name: "USB Interface", uid: "usb", numOutputs: 8, numInputs: 0)]
    }
    override func passThruDevice() -> AudioDevice? {
        .init(id: 5, name: "BlackHole 16ch", uid: "bh", numOutputs: 16, numInputs: 16)
    }
    
    override func availableAudioUnitEffects(includeMusicEffects: Bool = false) -> [AudioPluginDescriptor] {
        [.init(name: "Plugin 1", audioUnitDescription: AudioComponentDescription()),.init(name: "Plugin 2", audioUnitDescription: AudioComponentDescription())]
    }
}

#Preview {
    ContentView()
    .frame(width: 1200, height: 800)

}


// MARK: - TODOs & Hardening
// 1) Device format probing: read actual nominal sample rate/channels for each device and configure converters accordingly.
// 2) Channel mapping UI: expose a small matrix per destination (stereo here for brevity).
// 3) Better ring: replace with CoreAudio AudioRingBuffer (CARingBuffer) or TPCircularBuffer for lock‑free perf.
// 4) Latency control: measure total device latency (safety offset + IO buffer) and expose a user slider.
// 5) Error recovery: on device change/route change, re‑init affected AUHAL cleanly.
// 6) Multi‑channel: widen ASBDs and ioData copy to N channels; update UI to show meters per channel.
// 7) Monitoring: add a tap on the ring for VU meters (atomic peak capture to avoid locks).
// 8) Sandboxing/signing: app sandbox off (or proper entitlements) for HAL access and driver binding.
// 9) BlackHole dependency: ensure the virtual device exists (or ship your fork’s installer).
