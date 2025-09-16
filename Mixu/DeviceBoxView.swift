import SwiftUI

// MARK: - Models

enum DeviceType { case input, output, passthru }

struct Port: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var isInput: Bool          // input shown on right edge, output on left edge
    var uid: String?
    // Local offset inside the box (in points, from box's top-left)
    var local: CGPoint
}

struct DeviceBox: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var uid: String?
    var size: CGSize
    var origin: CGPoint        // Top-left position in the "patch" coordinate space
    var ports: [Port]
    var type: DeviceType
}

// MARK: - View

struct DeviceBoxView: View {
    @Binding var device: DeviceBox
    @Binding var draggingFrom: UUID?
    @Binding var tempPoint: CGPoint
    var onDropFrom: (UUID, CGPoint) -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.2))
                .frame(width: device.size.width, height: device.size.height)

            // Name
            Text(device.name)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .padding(4)

            // Ports
            ForEach(device.ports) { port in
                PortView(port: port, deviceSize: device.size) { portId, location in
                    onDropFrom(portId, location)
                }
            }
        }
        .frame(width: device.size.width, height: device.size.height)
        .position(x: device.origin.x + device.size.width/2,
                  y: device.origin.y + device.size.height/2)
    }
}
struct PortView: View {
    let port: Port
    let deviceSize: CGSize
    let onDrop: (UUID, CGPoint) -> Void
    
    @State private var isDragging = false
    @State private var globalPosition: CGPoint = .zero
    
    var body: some View {
        HStack(spacing: 4) {
            if port.isInput {
                Text(port.name)
                    .font(.system(size: 10))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: deviceSize.width * 0.6, alignment: .trailing)
                Circle()
                    .fill(.green)
                    .frame(width: 12, height: 12)
                    .background(PortPositionReader())
            } else {
                Circle()
                    .fill(.blue)
                    .frame(width: 12, height: 12)
                    .background(PortPositionReader())
                Text(port.name)
                    .font(.system(size: 10))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.leading)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: deviceSize.width * 0.6, alignment: .leading)
            }
        }
        .position(
            x: port.isInput ? deviceSize.width - 68 : 68,
            y: port.local.y
        )
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("patch"))
                .onChanged { value in
                    isDragging = true
                    onDrop(port.id, value.location)
                }
                .onEnded { value in
                    isDragging = false
                    onDrop(port.id, value.location)
                }
        )
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
// MARK: - Preview

#Preview {
    let ports = [
        Port(name: "In 1", isInput: false, uid: nil, local: CGPoint(x: 0,    y: 30)),
        Port(name: "Out 1",  isInput: true,  uid: nil, local: CGPoint(x: 120,  y: 70))
    ]
    return DeviceBoxView(
        device: .constant(DeviceBox(
            name: "Test Device",
            uid: nil,
            size: CGSize(width: 120, height: 100),
            origin: CGPoint(x: 100, y: 100),
            ports: ports,
            type: .output
        )),
        draggingFrom: .constant(nil),
        tempPoint: .constant(.zero),
        onDropFrom: { _, _ in }
    )
    .frame(width: 400, height: 300)
    .background(Color.black)
    .coordinateSpace(name: "patch")
}
