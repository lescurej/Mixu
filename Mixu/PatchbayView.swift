import SwiftUI
import CoreAudio
import AppKit
import AVFoundation
import os.log

struct Connection: Identifiable, Hashable {
    let id = UUID()
    var from: UUID
    var to: UUID
}

struct PatchbayView: View {
    @ObservedObject var engine: RouterEngine
    
    @State private var inputDevices: [DeviceBox] = []
    @State private var outputDevices: [DeviceBox] = []
    @State private var passThruDevice: [DeviceBox] = []
    @State private var connections: [Connection] = []
    @State private var draggingFrom: UUID? = nil
    @State private var tempPoint: CGPoint = .zero
    @State private var portPositions: [UUID: CGPoint] = [:]
    @State private var selectedConnection: [UUID] = []
    @State private var hoveredConnection: UUID? = nil
    
    @State private var marqueeStart: CGPoint? = nil
    @State private var marqueeCurrent: CGPoint? = nil
    @State private var isMarqueeing: Bool = false
    
    // Extracted connections layer
    private func connectionViews() -> some View {
        CableManagerViewWithGestures(
            connections: connections,
            portPositions: portPositions,
            selectedConnection: selectedConnection,
            hoveredConnection: hoveredConnection,
            onHover: { cableId in
                hoveredConnection = cableId
            },
            onClick: { cableId in
                handleCableSelection(cableId)
            },
        )
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                ZStack {
                    Color.black.opacity(0.0)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedConnection = []
                        }
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if marqueeStart == nil {
                                        marqueeStart = value.startLocation
                                    }
                                    marqueeCurrent = value.location
                                    isMarqueeing = true
                                }
                                .onEnded { value in
                                    if let start = marqueeStart, let current = marqueeCurrent {
                                        let marqueeRect = CGRect(
                                            x: min(start.x, current.x),
                                            y: min(start.y, current.y),
                                            width: abs(current.x - start.x),
                                            height: abs(current.y - start.y)
                                        )
                                        handleMarqueeEnd(marqueeRect)
                                    }
                                    marqueeStart = nil
                                    marqueeCurrent = nil
                                    isMarqueeing = false
                                }
                        )
                    
                    connectionViews()
                    
                    Canvas { ctx, _ in
                        if let fromId = draggingFrom, let fromPos = portPositions[fromId] {
                            ctx.stroke(curvePath(fromPos, tempPoint),
                                       with: .color(.orange),
                                       style: StrokeStyle(lineWidth: 2, dash: [6]))
                        }
                    }
                     .allowsHitTesting(false)
                    
                  
                    HStack(alignment: .top) {
                        VStack(spacing: 40.0){
                            ForEach($inputDevices) { $device in
                                DeviceBoxView(
                                    device: $device,
                                    draggingFrom: $draggingFrom,
                                    tempPoint: $tempPoint,
                                    onDrag: handleDrag,
                                    onRelease: { deviceBox, fromPortId, point in
                                        handleRelease(from: fromPortId, to: findClosestPort(at: point))
                                    }
                                )
                            }
                        }
                        .padding(10.0)
                        .frame(width: geometry.size.width/3)
                        
                        VStack(spacing: 40.0){
                            ForEach($passThruDevice) { $device in
                                DeviceBoxView(
                                    device: $device,
                                    draggingFrom: $draggingFrom,
                                    tempPoint: $tempPoint,
                                    onDrag: handleDrag,
                                    onRelease: { deviceBox, fromPortId, point in
                                        handleRelease(from: fromPortId, to: findClosestPort(at: point))
                                    }
                                )
                            }
                        }
                        .padding(10.0)
                        .frame(width: geometry.size.width/3)
                        
                        VStack(spacing: 40.0){
                            ForEach($outputDevices) { $device in
                                DeviceBoxView(
                                    device: $device,
                                    draggingFrom: $draggingFrom,
                                    tempPoint: $tempPoint,
                                    onDrag: handleDrag,
                                    onRelease: { deviceBox, fromPortId, point in
                                        handleRelease(from: fromPortId, to: findClosestPort(at: point))
                                    }
                                )
                            }
                            
                        }
                        .padding(10.0)
                        .frame(width: geometry.size.width/3)
                    }
                    
                    // Marquee rectangle on top
                    if let start = marqueeStart, let current = marqueeCurrent {
                        Rectangle()
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                            .background(Rectangle().fill(Color.blue.opacity(0.1)))
                            .frame(width: abs(current.x - start.x),
                                   height: abs(current.y - start.y))
                            .position(x: (start.x + current.x) / 2,
                                      y: (start.y + current.y) / 2)
                    }
                    
                }
                .coordinateSpace(name: "patch")
                .onPreferenceChange(PortPositionPreferenceKey.self) { positions in
                    updatePortPositions(positions)
                }
                .onAppear {
                    initializeDevices()
                }
            }
        }
        .onKeyDown { event in
            switch event.keyCode {
            case 51:
                deleteSelectedConnections()
            default:
                break
            }
        }
    }
    
    private func updatePortPositions(_ positions: [CGPoint]) {
        let allDevices = inputDevices + passThruDevice + outputDevices
        for (index, position) in positions.enumerated() {
            if index < allDevices.flatMap({ $0.ports }).count {
                let portId = allDevices.flatMap({ $0.ports })[index].id
                portPositions[portId] = position
            }
        }
    }
    
    private func initializeDevices() {
        let deviceWidth: CGFloat = 120
        
        // Clear existing devices
        inputDevices.removeAll()
        outputDevices.removeAll()
        passThruDevice.removeAll()
        
        // Add input devices (devices with inputs)
        let inputDeviceList = engine.availableInputs().filter { $0.name != engine.passThruName }
        for (index, device) in inputDeviceList.enumerated() {
            var ports: [Port] = []
            
            // Add output ports for input devices (they send audio)
            for i in 0..<device.numInputs {
                let yPos = 40 + CGFloat(i) * 30
                ports.append(Port(name: "Out \(i+1)", isInput: false, uid: device.uid, local: CGPoint(x: 0, y: yPos)))
            }
            
            self.inputDevices.append(DeviceBox(
                name: device.name,
                uid: device.uid,
                size: CGSize(width: deviceWidth, height: CGFloat(device.numInputs) * 30 + 50),
                origin: CGPoint(x: 0, y: 0),
                ports: ports,
                type: .input
            ))
        }
                
        // Add passthru device
        let passThru = engine.passThruDevice()
        var passthruPorts: [Port] = []
        // Add input ports for passthru
        for i in 0..<(passThru?.numInputs ?? 0) {
            let yPos = 40 + CGFloat(i) * 30
            passthruPorts.append(Port(name: "In \(i+1)", isInput: true, uid: passThru?.uid, local: CGPoint(x: 120, y: yPos)))
        }
        
        // Add output ports for passthru
        for i in 0..<(passThru?.numOutputs ?? 0) {
            let yPos = 40 + CGFloat(i) * 30
            passthruPorts.append(Port(name: "Out \(i+1)", isInput: false, uid: passThru?.uid, local: CGPoint(x: 0, y: yPos)))
        }
        
        self.passThruDevice.append(DeviceBox(
            name: passThru?.name ?? "None",
            uid: passThru?.uid,
            size: CGSize(width: deviceWidth, height: (max(CGFloat(passThru?.numInputs ?? 0),CGFloat(passThru?.numOutputs ?? 0)) * 30.0 + 50.0)),
            origin: CGPoint(x: 0, y: 0),
            ports: passthruPorts,
            type: .passthru
        ))

        // Add output devices
        let outputDeviceList = engine.availableOutputs().filter { $0.name != engine.passThruName }
        for (index, device) in outputDeviceList.enumerated() {
            var ports: [Port] = []
            // Add input ports for output devices (they receive audio)
            for i in 0..<device.numOutputs {
                let yPos = 40 + CGFloat(i) * 30
                ports.append(Port(name: "In \(i+1)", isInput: true, uid: device.uid, local: CGPoint(x: 120, y: yPos)))
            }
            
            self.outputDevices.append(DeviceBox(
                name: device.name,
                uid: device.uid,
                size: CGSize(width: deviceWidth, height: CGFloat(device.numOutputs) * 30 + 50),
                origin: CGPoint(x: 0, y: 0),
                ports: ports,
                type: .output
            ))
        }
    }
    
    private func handleDrag(device: DeviceBox, fromId: UUID, location: CGPoint) {
        draggingFrom = fromId
        tempPoint = location
    }
    
    private func handleRelease(from: UUID, to: UUID) {
        draggingFrom = nil
        tempPoint = CGPoint.zero
        
        guard let fromPort = findPort(by: from),
              let toPort = findPort(by: to),
              !fromPort.isInput && toPort.isInput else {
            return
        }
        
        let fromId = fromPort.id
        let toId = toPort.id
        
        if connections.contains(where: { $0.from == fromId && $0.to == toId }) == false {
            let connection = Connection(from: from, to: to)
            connections.append(connection)
            
            // Create audio connection in backend using port UIDs directly
            if let fromPortUID = fromPort.uid,
               let toPortUID = toPort.uid {
                engine.createAudioConnection(
                    id: connection.id,
                    fromDeviceUID: fromPortUID,
                    fromPort: 0, // Use 0 for now, we'll implement proper port indexing later
                    toDeviceUID: toPortUID,
                    toPort: 0
                )
            }
        }
    }

    private func handleCableSelection(_ cableId: UUID?) {
        guard let cableId = cableId else {
            selectedConnection = []
            return
        }
        
        // Check if shift key is pressed
        let isShiftPressed = NSEvent.modifierFlags.contains(.shift)
        
        if isShiftPressed {
            // Multi-selection mode
            if selectedConnection.contains(cableId) {
                // Remove from selection if already selected
                selectedConnection.removeAll { $0 == cableId }
            } else {
                // Add to selection
                selectedConnection.append(cableId)
            }
        } else {
            // Single selection mode
            selectedConnection = [cableId]
        }
    }

    private func deleteSelectedConnections() {
        guard !selectedConnection.isEmpty else { return }
        
        // Remove audio connections from backend
        for connectionId in selectedConnection {
            engine.removeAudioConnection(id: connectionId)
        }
        
        // Remove GUI connections
        connections.removeAll { connection in
            selectedConnection.contains(connection.id)
        }
        selectedConnection = []
    }

    private func handleMarqueeEnd(_ marqueeRect: CGRect) {
        let selectedCables = connections.filter { connection in
            guard let fromPos = portPositions[connection.from],
                  let toPos = portPositions[connection.to] else { return false }
            
            let cableRect = CGRect(
                x: min(fromPos.x, toPos.x) - 10,
                y: min(fromPos.y, toPos.y) - 10,
                width: abs(toPos.x - fromPos.x) + 20,
                height: abs(toPos.y - fromPos.y) + 20
            )
            
            return marqueeRect.intersects(cableRect)
        }
        
        selectedConnection = selectedCables.map { $0.id }
    }

    // Add helper function to find closest port
    private func findClosestPort(at point: CGPoint) -> UUID {
        var closestPort: UUID?
        var minDistance: CGFloat = CGFloat.greatestFiniteMagnitude
        
        for (portId, portPos) in portPositions {
            let distance = sqrt(pow(point.x - portPos.x, 2) + pow(point.y - portPos.y, 2))
            if distance < minDistance {
                minDistance = distance
                closestPort = portId
            }
        }
        
        return closestPort ?? UUID()
    }

    private func findDeviceForPort(_ port: Port) -> AudioDevice? {
        let allDevices = inputDevices + passThruDevice + outputDevices
        
        for deviceBox in allDevices {
            if deviceBox.ports.contains(where: { $0.id == port.id }) {
                if deviceBox.type == .input {
                    return engine.availableInputs().first { $0.name == deviceBox.name }
                } else if deviceBox.type == .output {
                    return engine.availableOutputs().first { $0.name == deviceBox.name }
                } else if deviceBox.type == .passthru {
                    return engine.passThruDevice()
                }
            }
        }
        return nil
    }

    private func getPortIndex(_ port: Port, in device: AudioDevice) -> Int {
        let allDevices = inputDevices + passThruDevice + outputDevices
        
        for deviceBox in allDevices {
            if deviceBox.name == device.name {
                if let index = deviceBox.ports.firstIndex(where: { $0.id == port.id }) {
                    return index
                }
            }
        }
        return 0
    }

    private func findPort(by id: UUID) -> Port? {
        let allDevices = inputDevices + passThruDevice + outputDevices
        
        for deviceBox in allDevices {
            if let port = deviceBox.ports.first(where: { $0.id == id }) {
                return port
            }
        }
        return nil
    }
}

// MARK: - Helpers

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}

func curvePath(_ from: CGPoint, _ to: CGPoint) -> Path {
    let controlPoint1 = CGPoint(x: from.x + (to.x - from.x) * 0.5, y: from.y)
    let controlPoint2 = CGPoint(x: to.x - (to.x - from.x) * 0.5, y: to.y)
    
    var path = Path()
    path.move(to: from)
    path.addCurve(to: to, control1: controlPoint1, control2: controlPoint2)
    return path
}

// MARK: - Preview with Mock Engine

final class MockRouterEngine: RouterEngine {
    override func availableInputs() -> [AudioDevice] {
        [
            AudioDevice(id: 1, name: "Built-in Mic", uid: "mic1", numOutputs: 0, numInputs: 2),
            AudioDevice(id: 2, name: "Virtual Mic", uid: "vmic", numOutputs: 0, numInputs: 4)
        ]
    }
    
    override func availableOutputs() -> [AudioDevice] {
        [
            AudioDevice(id: 3, name: "Speakers", uid: "spk", numOutputs: 2, numInputs: 0),
            AudioDevice(id: 4, name: "USB Interface", uid: "usb", numOutputs: 8, numInputs: 0)
        ]
    }
    
   override func passThruDevice() -> AudioDevice {
        AudioDevice(id: 5, name: "BlackHole 16ch", uid: "bh", numOutputs: 16, numInputs: 16)
    }
}

#Preview {
    PatchbayView(engine: MockRouterEngine())
        .frame(width: 1200, height: 800)
        .background(Color.black.opacity(0.8))
}
