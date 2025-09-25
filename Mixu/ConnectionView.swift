//
//  ConnectionView.swift
//  Mixu
//
//  Created by Johan Lescure on 17/09/2025.
//

import SwiftUI
import AppKit

// MARK: - Constants

private enum CableConstants {
    static let hitThreshold: CGFloat = 25
    static let selectedLineWidth: CGFloat = 3
    static let normalLineWidth: CGFloat = 2
    static let controlPointRatio: CGFloat = 0.5
}

// MARK: - Curve Shape

struct CurveShape: Shape {
    let from: CGPoint
    let to: CGPoint
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let controlPoint1 = CGPoint(
            x: from.x + (to.x - from.x) * CableConstants.controlPointRatio,
            y: from.y
        )
        let controlPoint2 = CGPoint(
            x: to.x - (to.x - from.x) * CableConstants.controlPointRatio,
            y: to.y
        )
        
        path.move(to: from)
        path.addCurve(to: to, control1: controlPoint1, control2: controlPoint2)
        return path
    }
}

// MARK: - Cable Manager View

struct CableManagerView: NSViewRepresentable {
    let connections: [Connection]
    let portPositions: [UUID: CGPoint]
    let selectedConnection: [UUID]
    let hoveredConnection: UUID?
    let onHover: (UUID?) -> Void
    let onClick: (UUID?) -> Void

    func makeNSView(context: Context) -> CableManagerNSView {
        CableManagerNSView(
            connections: connections,
            portPositions: portPositions,
            selectedConnection: selectedConnection,
            hoveredConnection: hoveredConnection,
            onHover: onHover,
            onClick: onClick,
        )
    }

    func updateNSView(_ nsView: CableManagerNSView, context: Context) {
        nsView.update(
            connections: connections,
            portPositions: portPositions,
            selectedConnection: selectedConnection,
            hoveredConnection: hoveredConnection
        )
    }
}

// MARK: - Cable Manager View with Gestures

struct CableManagerViewWithGestures: View {
    let connections: [Connection]
    let portPositions: [UUID: CGPoint]
    let selectedConnection: [UUID]
    let hoveredConnection: UUID?
    let onHover: (UUID?) -> Void
    let onClick: (UUID?) -> Void
    
    var body: some View {
        CableManagerView(
            connections: connections,
            portPositions: portPositions,
            selectedConnection: selectedConnection,
            hoveredConnection: hoveredConnection,
            onHover: onHover,
            onClick: onClick
        )
        // Remove the background gesture - let the parent handle drags
    }
}

// MARK: - Cable Manager NSView

final class CableManagerNSView: NSView {
    var connections: [Connection] = []
    var portPositions: [UUID: CGPoint] = [:]
    var selectedConnection: [UUID] = []  // Changed to array
    var hoveredConnection: UUID?
    var onHover: ((UUID?) -> Void)?
    var onClick: ((UUID?) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var lastHoveredCable: UUID?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

    init(connections: [Connection] = [],
         portPositions: [UUID: CGPoint] = [:],
         selectedConnection: [UUID] = [],  // Changed to array
         hoveredConnection: UUID? = nil,
         onHover: ((UUID?) -> Void)? = nil,
         onClick: ((UUID?) -> Void)? = nil) { // Add this
        self.connections = connections
        self.portPositions = portPositions
        self.selectedConnection = selectedConnection
        self.hoveredConnection = hoveredConnection
        self.onHover = onHover
        self.onClick = onClick
        super.init(frame: .zero)
        commonInit()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    
    private func commonInit() {
        wantsLayer = true
        setupEventMonitor()
    }
    
    deinit {
        teardownEventMonitor()
        teardownGlobalEventMonitor()
    }
    
    // MARK: - Public Methods
    
    func update(connections: [Connection],
                portPositions: [UUID: CGPoint],
                selectedConnection: [UUID],  // Changed to array
                hoveredConnection: UUID?) {
        self.connections = connections
        self.portPositions = portPositions
        self.selectedConnection = selectedConnection
        self.hoveredConnection = hoveredConnection
        needsDisplay = true
    }
    
    // MARK: - Event Monitoring
    
    private func setupEventMonitor() {
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self else { return event }
            
            let point = self.convert(event.locationInWindow, from: nil)
            let cableId = GeometryHelpers.findCableAtPoint(
                point,
                connections: self.connections,
                portPositions: self.portPositions
            )
            
            if let cableId = cableId {
                self.onClick?(cableId)
                return nil // Consume the event
            }
            
            return event // Let other events pass through
        }
    }
    
    private func teardownEventMonitor() {
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
    }
    
    private func handleLocalMouseDown(_ event: NSEvent) {
        let windowPoint = event.locationInWindow
        let viewPoint = convert(windowPoint, from: nil)
        
        guard bounds.contains(viewPoint) else { return }
        
        let cableId = GeometryHelpers.findCableAtPoint(
            viewPoint,
            connections: connections,
            portPositions: portPositions
        )
        onClick?(cableId)
    }

    private func teardownGlobalEventMonitor() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
    }
    
    // MARK: - Tracking Areas
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        
        if let existingArea = trackingArea {
            removeTrackingArea(existingArea)
        }
        
        let options: NSTrackingArea.Options = [
            .mouseMoved,
            .mouseEnteredAndExited,
            .activeInKeyWindow,
            .inVisibleRect
        ]
        
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: options,
            owner: self,
            userInfo: nil
        )
        
        if let area = trackingArea {
            addTrackingArea(area)
        }
    }
    
    // MARK: - Mouse Events
    
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let cableId = GeometryHelpers.findCableAtPoint(
            point,
            connections: connections,
            portPositions: portPositions
        )
        lastHoveredCable = cableId
        onHover?(cableId)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
    }
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Never capture mouse events - let them pass through
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        // Don't handle mouse events
    }
    
    // MARK: - Drawing
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        for connection in connections {
            drawConnection(connection)
        }
    }
    
    private func drawConnection(_ connection: Connection) {
        guard let fromPos = portPositions[connection.from],
              let toPos = portPositions[connection.to] else { return }
        
        let isSelected = selectedConnection.contains(connection.id)  // Check if in array
        let isHovered = hoveredConnection == connection.id
        
        let path = createPath(from: fromPos, to: toPos)
        configurePath(path, isSelected: isSelected, isHovered: isHovered)
        path.stroke()
    }
    
    private func createPath(from: CGPoint, to: CGPoint) -> NSBezierPath {
        let path = NSBezierPath()
        let control1 = CGPoint(
            x: from.x + (to.x - from.x) * CableConstants.controlPointRatio,
            y: from.y
        )
        let control2 = CGPoint(
            x: to.x - (to.x - from.x) * CableConstants.controlPointRatio,
            y: to.y
        )
        
        path.move(to: from)
        path.curve(to: to, controlPoint1: control1, controlPoint2: control2)
        return path
    }
    
    private func configurePath(_ path: NSBezierPath, isSelected: Bool, isHovered: Bool) {
        path.lineWidth = (isSelected || isHovered) ? CableConstants.selectedLineWidth : CableConstants.normalLineWidth
        path.lineCapStyle = .round
        
        let color: NSColor = isSelected ? .orange : (isHovered ? .yellow : .systemBlue)
        color.setStroke()
    }
    
    // MARK: - View Properties
    
    override var isFlipped: Bool { true }
}

// MARK: - Geometry Helpers

private enum GeometryHelpers {
    static func findCableAtPoint(_ point: CGPoint,
                                  connections: [Connection],
                                  portPositions: [UUID: CGPoint]) -> UUID? {
        for connection in connections.reversed() {
            guard let fromPos = portPositions[connection.from],
                  let toPos = portPositions[connection.to] else { continue }
            
            if isPointNearLine(point, start: fromPos, end: toPos) {
                return connection.id
            }
        }
        return nil
    }
    
    static func isPointNearLine(_ point: CGPoint,
                                start: CGPoint,
                                end: CGPoint,
                                threshold: CGFloat = CableConstants.hitThreshold) -> Bool {
        let vector = CGPoint(x: end.x - start.x, y: end.y - start.y)
        let pointVector = CGPoint(x: point.x - start.x, y: point.y - start.y)
        
        let lengthSquared = vector.x * vector.x + vector.y * vector.y
        
        guard lengthSquared > 0 else {
            let distance = sqrt(pointVector.x * pointVector.x + pointVector.y * pointVector.y)
            return distance <= threshold
        }
        
        let dotProduct = pointVector.x * vector.x + pointVector.y * vector.y
        let param = max(0, min(1, dotProduct / lengthSquared))
        
        let closestPoint = CGPoint(
            x: start.x + param * vector.x,
            y: start.y + param * vector.y
        )
        
        let distanceVector = CGPoint(
            x: point.x - closestPoint.x,
            y: point.y - closestPoint.y
        )
        
        let distance = sqrt(distanceVector.x * distanceVector.x + distanceVector.y * distanceVector.y)
        return distance <= threshold
    }
}

// MARK: - Temporary Connection View

struct TemporaryConnectionView: View {
    let from: CGPoint
    let to: CGPoint

    var body: some View {
        CurveShape(from: from, to: to)
            .stroke(
                Color.orange,
                style: StrokeStyle(
                    lineWidth: 3,
                    lineCap: .round
                )
            )
    }
}
