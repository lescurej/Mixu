import SwiftUI

// MARK: - Models

enum DeviceType { case input, output, passthru, plugin }

struct Port: Identifiable, Hashable, Equatable {
    let id = UUID()
    var name: String
    var device: AudioDevice?
    var pluginID: UUID?
    var index: Int
    var isInput: Bool          // input shown on right edge, output on left edge
    var uid: String?
    // Local offset inside the box (in points, from box's top-left)
    var local: CGPoint
    
    // MARK: - Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    // MARK: - Equatable conformance
    static func == (lhs: Port, rhs: Port) -> Bool {
        return lhs.id == rhs.id
    }
}

struct DeviceBox: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var uid: String?
    var size: CGSize
    var position: CGPoint      // View center in the patch coordinate space
    var ports: [Port] = []
    var type: DeviceType
    var pluginID: UUID? = nil
}

// MARK: - View

var portRadius: CGFloat = 12                    

struct DeviceBoxView: View {
    @Binding var device: DeviceBox
    @Binding var draggingFrom: UUID?
    @Binding var tempPoint: CGPoint
    var onDrag: (DeviceBox, UUID, CGPoint) -> Void
    var onRelease: (DeviceBox, UUID, CGPoint) -> Void
    var onMove: (DeviceBox) -> Void

    @State private var dragStartPosition: CGPoint? = nil

    var body: some View {
        let backgroundColor: Color = {
            switch device.type {
            case .input:
                return Color.blue.opacity(0.2)
            case .output:
                return Color.green.opacity(0.2)
            case .passthru:
                return Color.orange.opacity(0.2)
            case .plugin:
                return Color.purple.opacity(0.25)
            }
        }()

        ZStack {
            RoundedRectangle(cornerRadius: portRadius)
                .fill(backgroundColor)
                .frame(width: device.size.width, height: device.size.height)
                .overlay(
                    RoundedRectangle(cornerRadius: portRadius)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
                .onDrag {
                    let provider = NSItemProvider(object: NSString(string: device.id.uuidString))
                    provider.suggestedName = device.name
                    return provider
                }

            // Name
            Text(device.name)
                .font(.caption)
                .frame(maxWidth: device.size.width*0.5)
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(4)

            // Ports
            ForEach(device.ports) { port in
                PortView(port: port,
                         deviceSize: device.size,
                         onDrag: { portId, location in
                    onDrag(device, portId, location)},
                         onReleased: { portId, location in
                    onRelease(device, portId, location)}
                )
            }
        }
        .frame(width: device.size.width, height: device.size.height)
        .position(device.position)
        .gesture(boxDragGesture)
        .onAppear { onMove(device) }
    }

    private var boxDragGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("patch"))
            .onChanged { value in
                guard draggingFrom == nil else { return }
                if dragStartPosition == nil {
                    dragStartPosition = device.position
                }
                if let start = dragStartPosition {
                    device.position = CGPoint(x: start.x + value.translation.width,
                                              y: start.y + value.translation.height)
                    onMove(device)
                }
            }
            .onEnded { value in
                guard draggingFrom == nil else { dragStartPosition = nil; return }
                if let start = dragStartPosition {
                    device.position = CGPoint(x: start.x + value.translation.width,
                                              y: start.y + value.translation.height)
                    onMove(device)
                }
                dragStartPosition = nil
            }
    }
}

let hoveredCircleSize = CGFloat(15)
let normalCircleSize = CGFloat(12)

struct PortView: View {
    let port: Port
    let deviceSize: CGSize
    let onDrag: (UUID, CGPoint) -> Void
    let onReleased: (UUID, CGPoint) -> Void
    
    @State private var hovered: Bool = false
    
    var body: some View {
        ZStack {
            // Port circle with position reader
            Circle()
                .fill(port.isInput ? .green : .blue)
                .frame(width: hovered ? hoveredCircleSize : normalCircleSize , height: hovered ? hoveredCircleSize : normalCircleSize)
                .position(
                    x: port.isInput ? deviceSize.width : 0 ,
                    y: port.local.y
                )
                .onHover(perform: {hovered in self.hovered = hovered})
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("patch"))
                        .onChanged { value in
                            onDrag(port.id, value.location)
                        }
                        .onEnded { value in
                            onReleased(port.id, value.location)
                        }
                )
                
            
            // Port label
            Text(port.name)
                .font(.system(size: 10))
                .fontWeight(.thin)
                .foregroundColor(.white)
                .lineLimit(1)
                .multilineTextAlignment(port.isInput ? .trailing : .leading )
                .frame(width: 100.0)
                .position(
                    x: port.isInput ? deviceSize.width - 20 : 20,
                    y: port.local.y
                )
        }
    }
}
