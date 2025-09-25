import SwiftUI

// MARK: - Models

enum DeviceType { case input, output, passthru }

struct Port: Identifiable, Hashable, Equatable {    
    let id = UUID()
    var name: String
    var device: AudioDevice
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
    var origin: CGPoint        // Top-left position in the "patch" coordinate space
    var ports: [Port] = []
    var type: DeviceType
}

// MARK: - View

var portRadius: CGFloat = 12                    

struct DeviceBoxView: View {
    @Binding var device: DeviceBox
    @Binding var draggingFrom: UUID?
    @Binding var tempPoint: CGPoint
    var onDrag: (DeviceBox, UUID, CGPoint) -> Void
    var onRelease: (DeviceBox, UUID, CGPoint) -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: portRadius)
                .fill(Color.gray.opacity(0.2))
                .frame(width: device.size.width, height: device.size.height)

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
    }
}

let hoveredCircleSize = CGFloat(15)
let normalCircleSize = CGFloat(12)

struct PortView: View {
    let port: Port
    let deviceSize: CGSize
    let onDrag: (UUID, CGPoint) -> Void
    let onReleased: (UUID, CGPoint) -> Void
    
    @State private var globalPosition: CGPoint = .zero
    @State private var hovered: Bool = false
    
    var body: some View {
        ZStack {
            // Port circle with position reader
            Circle()
                .fill(port.isInput ? .green : .blue)
                .frame(width: hovered ? hoveredCircleSize : normalCircleSize , height: hovered ? hoveredCircleSize : normalCircleSize)
                .background(PortPositionReader())
                .position(
                    x: port.isInput ? 0 : deviceSize.width ,
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
                .multilineTextAlignment(port.isInput ? .leading : .trailing )
                .frame(width: 100.0)
                .position(
                    x: port.isInput ? 20: deviceSize.width - 20,
                    y: port.local.y
                )
        }
    }
}

struct PortPositionReader: View {
    var body: some View {
        GeometryReader { geo in
            Color.clear
                .preference(
                    key: PortPositionPreferenceKey.self,
                    value: [geo.frame(in: .named("patch")).center]
                )
        }
    }
}

struct PortPositionPreferenceKey: PreferenceKey {
    static var defaultValue: [CGPoint] = []
    
    static func reduce(value: inout [CGPoint], nextValue: () -> [CGPoint]) {
        value.append(contentsOf: nextValue())
    }
}

extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

/*
// MARK: - Preview

#Preview {
    var device = DeviceBox(
        name: "Test Device",
        uid: nil,
        size: CGSize(width: 120, height: 100),
        origin: CGPoint(x: 100, y: 100),
        type: .output
    )
    let ports = [
        Port(name: "In 1", device: device, index: 0, isInput: false, uid: nil, local: CGPoint(x: 0,    y: 30)),
        Port(name: "Out 1", device: device, index: 0,  isInput: true, uid: nil, local: CGPoint(x: 120,  y: 70))
    ]
    device.ports.append(contentsOf: ports)
    
    DeviceBoxView(
        device: .constant(device),
        draggingFrom: .constant(nil),
        tempPoint: .constant(.zero),
        onDrag: { device, _, _ in },
        onRelease: { device, _, _ in },
    )
    .frame(width: 400, height: 300)
    .background(Color.black)
    .coordinateSpace(name: "patch")
}
*/
