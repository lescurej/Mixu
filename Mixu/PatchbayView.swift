import SwiftUI
import UniformTypeIdentifiers

struct Connection: Identifiable, Hashable {
    let id = UUID()
    var from: UUID
    var to: UUID
}

struct PatchbayView: View {
    @ObservedObject var engine: RouterEngine

    @State private var availableInputs: [AudioDevice] = []
    @State private var availableOutputs: [AudioDevice] = []
    @State private var passthruDevice: AudioDevice? = nil
    @State private var availablePlugins: [AudioPluginDescriptor] = []

    @State private var placedBoxes: [DeviceBox] = []
    @State private var lockedSidebarItems: Set<String> = []

    @State private var connections: [Connection] = []
    @State private var portCenters: [UUID: CGPoint] = [:]
    @State private var draggingFrom: UUID? = nil
    @State private var tempPoint: CGPoint = .zero

    @State private var isDropTargeted = false
    @State private var patchSize: CGSize = CGSize(width: 2400, height: 1600)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            patchSurface
        }
        .background(Color.black.opacity(0.92))
        .onAppear { reloadCatalog() }
    }
}

private extension PatchbayView {
    var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                sidebarSection(
                    title: "INPUTS",
                    color: .blue,
                    items: availableInputs.map { SidebarItem(device: $0, type: .input) }
                )
                if let passthruDevice {
                    sidebarSection(
                        title: "PASS-THRU",
                        color: .orange,
                        items: [SidebarItem(device: passthruDevice, type: .passthru)]
                    )
                }
                sidebarSection(
                    title: "OUTPUTS",
                    color: .green,
                    items: availableOutputs.map { SidebarItem(device: $0, type: .output) }
                )
                sidebarSection(
                    title: "PLUG-INS",
                    color: .purple,
                    items: availablePlugins.map { SidebarItem(plugin: $0) }
                )
            }
            .padding(.vertical, 22)
            .padding(.horizontal, 16)
        }
        .frame(width: 260)
        .background(Color.black.opacity(0.78))
    }

    @ViewBuilder
    func sidebarSection(title: String, color: Color, items: [SidebarItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(color.opacity(0.75))
                    .textCase(.uppercase)
                ForEach(items) { item in
                    sidebarRow(for: item, accent: color)
                }
            }
        }
    }

    func sidebarRow(for item: SidebarItem, accent: Color) -> some View {
        let disabled = lockedSidebarItems.contains(item.id) && !item.allowsMultiplePlacement
        return HStack(spacing: 10) {
            Image(systemName: item.iconName)
                .frame(width: 18)
                .foregroundStyle(accent)
            Text(item.title)
                .font(.callout)
                .foregroundStyle(Color.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(accent.opacity(disabled ? 0.12 : 0.2))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(accent.opacity(disabled ? 0.0 : 0.35), lineWidth: 1)
        )
        .opacity(disabled ? 0.35 : 1)
        .onDrag {
            let provider = NSItemProvider(object: NSString(string: item.id))
            provider.suggestedName = item.title
            return provider
        }
        .disabled(disabled)
    }

    var patchSurface: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            GeometryReader { geo in
                let bounds = geo.size
                ZStack {
                Color.black.opacity(0.82)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Color.white.opacity(0.04), lineWidth: 1)
                    )
                    .ignoresSafeArea()

                Canvas { ctx, _ in
                    for connection in connections {
                        if let from = portCenters[connection.from], let to = portCenters[connection.to] {
                            ctx.stroke(curve(from, to), with: .color(.blue.opacity(0.9)), lineWidth: 3)
                        }
                    }

                    if let from = draggingFrom, let start = portCenters[from] {
                        ctx.stroke(
                            curve(start, tempPoint),
                            with: .color(.orange),
                            style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                        )
                    }
                }
                .allowsHitTesting(false)

                ForEach($placedBoxes) { $box in
                    DeviceBoxView(
                        device: $box,
                        draggingFrom: $draggingFrom,
                        tempPoint: $tempPoint,
                        onDrag: { _, fromId, location in
                            draggingFrom = fromId
                            tempPoint = location
                        },
                        onRelease: { _, fromPortId, location in
                            handleConnectionDrop(fromId: fromPortId, location: location)
                            draggingFrom = nil
                        },
                        onMove: { updated in
                            updatePosition(for: updated, bounds: patchSize)
                        }
                    )
                }

                if placedBoxes.isEmpty {
                    Text("Drag and drop devices here")
                        .font(.callout)
                        .foregroundColor(.white.opacity(0.4))
                        .padding(12)
                }
                }
                .padding(16)
                .coordinateSpace(name: "patch")
                .onAppear {
                    updatePatchSizeIfNeeded(bounds)
                }
                .onChange(of: bounds) { _, newBounds in
                    updatePatchSizeIfNeeded(newBounds)
                }
                .onDrop(
                    of: [UTType.plainText],
                    delegate: SidebarDropDelegate(
                        onHighlight: { isDropTargeted = $0 },
                        perform: { identifier, location in
                            handleSidebarDrop(identifier: identifier, location: location, bounds: patchSize)
                        }
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.blue.opacity(isDropTargeted ? 0.45 : 0), lineWidth: 2)
                )
                .frame(width: max(patchSize.width, geo.size.width), height: max(patchSize.height, geo.size.height))
            }
            .frame(minWidth: patchSize.width, minHeight: patchSize.height)
        }
    }

    func handleSidebarDrop(identifier: String, location: CGPoint, bounds: CGSize) -> Bool {
        guard let item = allSidebarItems.first(where: { $0.id == identifier }) else { return false }

        switch item.kind {
        case let .device(device, type):
            guard !lockedSidebarItems.contains(item.id) || item.allowsMultiplePlacement else { return false }
            let box = makeDeviceBox(for: device, type: type, at: location, bounds: bounds)
            placedBoxes.append(box)
            if !item.allowsMultiplePlacement {
                lockedSidebarItems.insert(item.id)
            }
            recomputePortCenters()
            return true

        case let .plugin(descriptor):
            do {
                try createPluginBox(descriptor: descriptor, at: location, bounds: bounds)
                recomputePortCenters()
                return true
            } catch {
                print("Failed to create plugin node: \(error)")
                return false
            }
        }
    }

    func makeDeviceBox(for device: AudioDevice, type: DeviceType, at location: CGPoint, bounds: CGSize) -> DeviceBox {
        let width: CGFloat = 220
        let (outputCount, inputCount): (Int, Int) = {
            switch type {
            case .input:
                return (max(device.numInputs, 1), 0)
            case .output:
                return (0, max(device.numOutputs, 1))
            case .passthru:
                return (max(device.numOutputs, 1), max(device.numInputs, 1))
            case .plugin:
                return (0, 0)
            }
        }()

        let totalPorts = max(outputCount, inputCount)
        let height = boxHeight(for: totalPorts)
        var ports: [Port] = []

        if outputCount > 0 {
            for index in 0..<outputCount {
                let y = portY(for: index, total: outputCount, height: height)
                ports.append(
                    Port(
                        name: "Out \(index + 1)",
                        device: device,
                        pluginID: nil,
                        index: index,
                        isInput: false,
                        uid: device.uid,
                        local: CGPoint(x: 0, y: y)
                    )
                )
            }
        }

        if inputCount > 0 {
            for index in 0..<inputCount {
                let y = portY(for: index, total: inputCount, height: height)
                ports.append(
                    Port(
                        name: "In \(index + 1)",
                        device: device,
                        pluginID: nil,
                        index: index,
                        isInput: true,
                        uid: device.uid,
                        local: CGPoint(x: 0, y: y)
                    )
                )
            }
        }

        var box = DeviceBox(
            name: device.name,
            uid: device.uid,
            size: CGSize(width: width, height: height),
            position: location,
            ports: ports,
            type: type
        )
        box.position = clampPosition(location, size: box.size, in: bounds)
        return box
    }

    func createPluginBox(descriptor: AudioPluginDescriptor, at location: CGPoint, bounds: CGSize) throws {
        let info = try engine.createPluginNode(descriptor: descriptor, channelCount: 2)
        let channelCount = max(info.channelCount, 1)
        let width: CGFloat = 220
        let height = boxHeight(for: channelCount)

        var ports: [Port] = []
        for index in 0..<channelCount {
            let y = portY(for: index, total: channelCount, height: height)
            ports.append(
                Port(
                    name: "Out \(index + 1)",
                    device: nil,
                    pluginID: info.id,
                    index: index,
                    isInput: false,
                    uid: nil,
                    local: CGPoint(x: 0, y: y)
                )
            )
        }
        for index in 0..<channelCount {
            let y = portY(for: index, total: channelCount, height: height)
            ports.append(
                Port(
                    name: "In \(index + 1)",
                    device: nil,
                    pluginID: info.id,
                    index: index,
                    isInput: true,
                    uid: nil,
                    local: CGPoint(x: 0, y: y)
                )
            )
        }

        var box = DeviceBox(
            name: info.name,
            uid: nil,
            size: CGSize(width: width, height: height),
            position: location,
            ports: ports,
            type: .plugin,
            pluginID: info.id
        )
        box.position = clampPosition(location, size: box.size, in: bounds)
        placedBoxes.append(box)
    }

    func handleConnectionDrop(fromId: UUID, location: CGPoint) {
        guard let fromPort = allPorts().first(where: { $0.id == fromId }) else { return }

        let maybeTarget = portCenters
            .filter { $0.key != fromId }
            .min { a, b in
                a.value.distance(to: location) < b.value.distance(to: location)
            }?.key

        guard
            let toId = maybeTarget,
            let toPort = allPorts().first(where: { $0.id == toId }),
            fromPort.isInput != toPort.isInput,
            let fromPoint = portCenters[fromId],
            let toPoint = portCenters[toId]
        else {
            return
        }

        let hitRadius: CGFloat = 18
        let valid = fromPoint.distance(to: location) <= hitRadius || toPoint.distance(to: location) <= hitRadius
        guard valid else { return }

        let (source, destination) = fromPort.isInput ? (toId, fromId) : (fromId, toId)
        if !connections.contains(where: { $0.from == source && $0.to == destination }) {
            connections.append(Connection(from: source, to: destination))
        }

        if !fromPort.isInput,
           let uid = toPort.device?.uid,
           let outputDevice = engine.availableOutputs().first(where: { $0.uid == uid }) {
            engine.toggleOutput(outputDevice, enabled: true)
        }
    }

    func updatePosition(for updatedDevice: DeviceBox, bounds: CGSize) {
        guard let index = placedBoxes.firstIndex(where: { $0.id == updatedDevice.id }) else { return }
        var device = updatedDevice
        device.position = clampPosition(device.position, size: device.size, in: bounds)
        placedBoxes[index] = device
        recomputePortCenters()
    }

    func recomputePortCenters() {
        var centers: [UUID: CGPoint] = [:]
        for box in placedBoxes {
            let originX = box.position.x - box.size.width / 2
            let originY = box.position.y - box.size.height / 2
            for port in box.ports {
                // Match visual placement in DeviceBoxView.PortView:
                // - Inputs on left edge
                // - Outputs on right edge
                let x = originX + (port.isInput ? 0 : box.size.width)
                let y = originY + port.local.y
                centers[port.id] = CGPoint(x: x, y: y)
            }
        }
        portCenters = centers
    }

    func reloadCatalog() {
        availableInputs = engine.availableInputs().sorted { $0.name < $1.name }
        availableOutputs = engine.availableOutputs().sorted { $0.name < $1.name }
        passthruDevice = engine.passThruDevice()
        availablePlugins = engine.availableAudioUnitEffects().sorted { $0.name < $1.name }

        let validIdentifiers = Set(allSidebarItems.map(\.id))
        lockedSidebarItems = lockedSidebarItems.filter { validIdentifiers.contains($0) }
    }

    func updatePatchSizeIfNeeded(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let newSize = CGSize(width: max(size.width, patchSize.width), height: max(size.height, patchSize.height))
        guard patchSize != newSize else { return }
        patchSize = newSize
        placedBoxes = placedBoxes.map { box in
            var updated = box
            updated.position = clampPosition(box.position, size: box.size, in: newSize)
            return updated
        }
        recomputePortCenters()
    }

    func clampPosition(_ position: CGPoint, size: CGSize, in bounds: CGSize) -> CGPoint {
        guard bounds.width > 0, bounds.height > 0 else { return position }
        let halfWidth = size.width / 2
        let halfHeight = size.height / 2
        let x = min(max(position.x, halfWidth), bounds.width - halfWidth)
        let y = min(max(position.y, halfHeight), bounds.height - halfHeight)
        return CGPoint(x: x, y: y)
    }

    func allPorts() -> [Port] {
        placedBoxes.flatMap(\.ports)
    }

    func curve(_ a: CGPoint, _ b: CGPoint) -> Path {
        var path = Path()
        path.move(to: a)
        let midX = (a.x + b.x) / 2
        path.addCurve(
            to: b,
            control1: CGPoint(x: midX, y: a.y),
            control2: CGPoint(x: midX, y: b.y)
        )
        return path
    }

    var allSidebarItems: [SidebarItem] {
        var items: [SidebarItem] = []
        items.append(contentsOf: availableInputs.map { SidebarItem(device: $0, type: .input) })
        if let passthruDevice {
            items.append(SidebarItem(device: passthruDevice, type: .passthru))
        }
        items.append(contentsOf: availableOutputs.map { SidebarItem(device: $0, type: .output) })
        items.append(contentsOf: availablePlugins.map { SidebarItem(plugin: $0) })
        return items
    }

    func boxHeight(for portCount: Int) -> CGFloat {
        let minimumHeight: CGFloat = 120
        let dynamicHeight = CGFloat(portCount + 1) * 22 + 24
        return max(minimumHeight, dynamicHeight)
    }

    func portY(for index: Int, total: Int, height: CGFloat) -> CGFloat {
        height / CGFloat(total + 1) * CGFloat(index + 1)
    }
}

private struct SidebarItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case device(AudioDevice, DeviceType)
        case plugin(AudioPluginDescriptor)
    }

    let id: String
    let title: String
    let kind: Kind
    let iconName: String
    let allowsMultiplePlacement: Bool

    init(device: AudioDevice, type: DeviceType) {
        self.id = "\(type.sidebarIdentifier).\(device.uid)"
        self.title = device.name
        self.kind = .device(device, type)
        self.iconName = {
            switch type {
            case .input: return "arrow.down.right.circle"
            case .output: return "arrow.up.right.circle"
            case .passthru: return "arrow.left.and.right.circle"
            case .plugin: return "slider.horizontal.3"
            }
        }()
        self.allowsMultiplePlacement = false
    }

    init(plugin descriptor: AudioPluginDescriptor) {
        self.id = "plugin.\(descriptor.id.uuidString)"
        self.title = descriptor.name
        self.kind = .plugin(descriptor)
        self.iconName = "slider.horizontal.3"
        self.allowsMultiplePlacement = true
    }
}

private struct SidebarDropDelegate: DropDelegate {
    let onHighlight: (Bool) -> Void
    let perform: (String, CGPoint) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.plainText])
    }

    func dropEntered(info: DropInfo) {
        onHighlight(true)
    }

    func dropExited(info: DropInfo) {
        onHighlight(false)
    }

    func performDrop(info: DropInfo) -> Bool {
        onHighlight(false)
        guard let provider = info.itemProviders(for: [UTType.plainText]).first else { return false }
        let location = info.location
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
            guard error == nil else { return }
            let identifier: String?
            if let data = item as? Data {
                identifier = String(data: data, encoding: .utf8)
            } else if let string = item as? String {
                identifier = string
            } else if let nsString = item as? NSString {
                identifier = nsString as String
            } else {
                identifier = nil
            }
            guard let identifier else { return }
            DispatchQueue.main.async {
                _ = perform(identifier, location)
            }
        }
        return true
    }
}

private extension DeviceType {
    var sidebarIdentifier: String {
        switch self {
        case .input: return "input"
        case .output: return "output"
        case .passthru: return "passthru"
        case .plugin: return "plugin"
        }
    }
}

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}

#Preview {
    PatchbayView(engine: MockRouterEngine())
        .frame(width: 1200, height: 800)
}
