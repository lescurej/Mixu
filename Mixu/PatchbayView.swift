import SwiftUI
import CoreAudio

struct Connection: Identifiable, Hashable {
    let id = UUID()
    var from: UUID
    var to: UUID
}
struct PatchbayView: View {
    @ObservedObject var engine: RouterEngine
    
    @State private var devices: [DeviceBox] = []
    @State private var connections: [Connection] = []
    @State private var draggingFrom: UUID? = nil
    @State private var tempPoint: CGPoint = .zero
    @State private var portPositions: [UUID: CGPoint] = [:]
    
    var body: some View {
        ZStack {
            // Cables
            Canvas { ctx, _ in
                // Draw existing connections
                for conn in connections {
                    if let fromPos = portPositions[conn.from],
                       let toPos = portPositions[conn.to] {
                        ctx.stroke(curvePath(fromPos, toPos), with: .color(.blue), lineWidth: 3)
                    }
                }
                
                // Draw temporary connection
                if let fromId = draggingFrom, let fromPos = portPositions[fromId] {
                    ctx.stroke(curvePath(fromPos, tempPoint),
                              with: .color(.orange),
                              style: StrokeStyle(lineWidth: 2, dash: [6]))
                }
            }
            
            // Devices
            ForEach($devices) { $device in
                DeviceBoxView(
                    device: $device,
                    draggingFrom: $draggingFrom,
                    tempPoint: $tempPoint,
                    onDropFrom: handleDragEnded
                )
            }
        }
        .coordinateSpace(name: "patch")
        .onPreferenceChange(PortPositionPreferenceKey.self) { positions in
            // Update port positions from preferences
            for (index, position) in positions.enumerated() {
                if index < devices.flatMap({ $0.ports }).count {
                    let portId = devices.flatMap({ $0.ports })[index].id
                    portPositions[portId] = position
                }
            }
        }
    }
    
    private func handleDragEnded(fromId: UUID, location: CGPoint) {
        // Si on commence à glisser
        if draggingFrom == nil {
            draggingFrom = fromId
            tempPoint = location
            return
        }
        
        // Si on termine le glisser
        guard let sourceId = draggingFrom else { return }
        draggingFrom = nil
        
        // Trouver le port le plus proche du point de dépôt
        var closestPort: UUID? = nil
        var minDistance: CGFloat = 20 // Distance maximale pour une connexion
        
        for (portId, position) in portPositions {
            // Ne pas se connecter à soi-même
            if portId == sourceId { continue }
            
            // Vérifier que les ports sont de types opposés
            guard let sourcePort = devices.flatMap({ $0.ports }).first(where: { $0.id == sourceId }),
                  let targetPort = devices.flatMap({ $0.ports }).first(where: { $0.id == portId }),
                  sourcePort.isInput != targetPort.isInput else { continue }
            
            let distance = position.distance(to: location)
            if distance < minDistance {
                minDistance = distance
                closestPort = portId
            }
        }
        
        // Créer la connexion si un port compatible a été trouvé
        if let targetId = closestPort {
            let sourcePort = devices.flatMap({ $0.ports }).first(where: { $0.id == sourceId })!
            let targetPort = devices.flatMap({ $0.ports }).first(where: { $0.id == targetId })!
            
            // Déterminer qui est l'entrée et qui est la sortie
            let from = sourcePort.isInput ? targetId : sourceId
            let to = sourcePort.isInput ? sourceId : targetId
            
            // Ajouter la connexion
            connections.append(Connection(from: from, to: to))
            
            // Activer la sortie audio si nécessaire
            if let uid = targetPort.uid, !sourcePort.isInput,
               let dev = engine.availableOutputs().first(where: { $0.uid == uid }) {
                engine.toggleOutput(dev, enabled: true)
            }
        }
    }
}

// MARK: - Helpers

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}

/*
// MARK: - Preview with Mock Engine

final class MockRouterEngine: RouterEngine {
    override func availableInputs() -> [AudioDevice] {
        [
            .fake(name: "Built-in Mic", uid: "mic1", inputs: 2, outputs: 0),
            .fake(name: "Virtual Mic",  uid: "vmic", inputs: 4, outputs: 0)
        ]
    }
    override func availableOutputs() -> [AudioDevice] {
        [
            .fake(name: "Speakers", uid: "spk", inputs: 0, outputs: 2),
            .fake(name: "USB Interface", uid: "usb", inputs: 0, outputs: 8)
        ]
    }
    override func getPassThru() -> AudioDevice {
        .fake(name: "BlackHole 16ch", uid: "bh", inputs: 16, outputs: 16)
    }
}

#Preview {
    PatchbayView(engine: MockRouterEngine())
        .frame(width: 1200, height: 800)
}
*/
