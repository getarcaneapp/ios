import SwiftUI
import Arcane

struct NetworkTopologyView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let environmentID: EnvironmentID

    @State private var topology: NetworkTopology?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedNode: TopologyNode?

    private var clientIdentity: ObjectIdentifier? {
        manager.client.map { ObjectIdentifier($0.transport) }
    }

    var body: some View {
        Group {
            if isLoading && topology == nil {
                ProgressView("Loading network topology…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if manager.client == nil && topology == nil {
                ContentUnavailableView {
                    Label("Connection Unavailable", systemImage: "wifi.slash")
                } description: {
                    Text("Waiting for the Arcane connection to become available.")
                }
            } else if let errorMessage, topology == nil {
                ContentUnavailableView {
                    Label("Couldn't Load Topology", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") {
                        Task { await loadTopology() }
                    }
                }
            } else if let topology, topology.nodes.isEmpty {
                ContentUnavailableView {
                    Label("No Network Topology", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                } description: {
                    Text("No network or container topology data is available for this environment.")
                }
            } else if let topology {
                NetworkTopologyDiagram(topology: topology, selectedNode: $selectedNode)
                    .id(topology)
            } else {
                ProgressView("Preparing network topology…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Network Topology")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await loadTopology(refresh: true) }
                } label: {
                    if isLoading && topology != nil {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isLoading)
                .accessibilityLabel("Refresh network topology")
            }
        }
        .task(id: clientIdentity) { await loadTopology() }
        .sheet(item: $selectedNode) { node in
            if let topology {
                TopologyNodeDetailSheet(node: node, topology: topology)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private func loadTopology(refresh: Bool = false) async {
        guard !isLoading, let client = manager.client else { return }
        isLoading = true
        if topology == nil {
            errorMessage = nil
        }
        defer { isLoading = false }

        do {
            let response = try await client.networks.topology(envID: environmentID)
            topology = response
            errorMessage = nil
            selectedNode = nil
        } catch {
            let message = friendlyErrorMessage(error)
            if topology == nil {
                errorMessage = message
            } else if refresh {
                showToast(.error(message))
            }
        }
    }
}

private struct NetworkTopologyDiagram: View {
    private static let minimumScale: CGFloat = 0.35
    private static let maximumScale: CGFloat = 1.75

    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding private var selectedNode: TopologyNode?
    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var gestureScale: CGFloat = 1

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var viewportSize: CGSize = .zero
    @State private var hasFitted = false

    private let graph: TopologyGraphLayout

    init(topology: NetworkTopology, selectedNode: Binding<TopologyNode?>) {
        graph = TopologyGraphLayout(topology: topology)
        _selectedNode = selectedNode
    }

    private var displayedScale: CGFloat {
        Self.clamped(scale * gestureScale)
    }

    private var displayedOffset: CGSize {
        CGSize(
            width: offset.width + dragTranslation.width,
            height: offset.height + dragTranslation.height
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                TopologyGridBackground()

                graphContent
                    .frame(width: graph.contentSize.width, height: graph.contentSize.height)
                    .scaleEffect(displayedScale)
                    .offset(displayedOffset)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
            .simultaneousGesture(panGesture)
            .simultaneousGesture(zoomGesture)
            .overlay(alignment: .topLeading) {
                legend
                    .padding(12)
            }
            .overlay(alignment: .bottomTrailing) {
                fitButton
                    .padding(12)
            }
            .background(Color(.systemGroupedBackground))
            .compositingGroup()
            .clipShape(.rect(cornerRadius: Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .stroke(Color(.separator).opacity(0.45), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .onChange(of: proxy.size, initial: true) { _, newSize in
                viewportSize = newSize
                fitGraph(in: newSize, animated: hasFitted)
                hasFitted = true
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var graphContent: some View {
        ZStack(alignment: .topLeading) {
            TopologyEdgeCanvas(graph: graph)
                .frame(width: graph.contentSize.width, height: graph.contentSize.height)
                .accessibilityHidden(true)

            ForEach(graph.nodes) { node in
                TopologyNodeCard(
                    node: node,
                    connections: graph.connectionsByNode[node.id] ?? [],
                    selectedNode: $selectedNode
                )
                .frame(
                    width: graph.size(for: node).width,
                    height: graph.size(for: node).height
                )
                .position(graph.position(for: node))
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 8) {
            Label("Networks", systemImage: "network")
                .foregroundStyle(.teal)
            Label("Containers", systemImage: "shippingbox")
                .foregroundStyle(.green)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Diagram legend: teal nodes are networks, status-colored nodes are containers")
    }

    private var fitButton: some View {
        Button {
            fitGraph(in: viewportSize, animated: true)
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .frame(width: 40, height: 40)
                .background(.regularMaterial, in: .circle)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("Fit topology to screen")
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 5)
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                offset = CGSize(
                    width: offset.width + value.translation.width,
                    height: offset.height + value.translation.height
                )
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .updating($gestureScale) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                scale = Self.clamped(scale * value.magnification)
            }
    }

    private func fitGraph(in viewport: CGSize, animated: Bool) {
        guard viewport.width > 0, viewport.height > 0 else { return }
        let horizontalScale = (viewport.width - 32) / graph.contentSize.width
        let verticalScale = (viewport.height - 32) / graph.contentSize.height
        let targetScale = Self.clamped(min(horizontalScale, verticalScale, 1))

        let update = {
            scale = targetScale
            offset = .zero
        }
        if animated {
            withAnimation(Motion.reduced(Motion.reflow, reduceMotion: reduceMotion), update)
        } else {
            update()
        }
    }

    private static func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, minimumScale), maximumScale)
    }
}

private struct TopologyGridBackground: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 18
            var path = Path()
            for x in stride(from: spacing / 2, through: size.width, by: spacing) {
                for y in stride(from: spacing / 2, through: size.height, by: spacing) {
                    path.addEllipse(in: CGRect(x: x, y: y, width: 1.5, height: 1.5))
                }
            }
            context.fill(path, with: .color(Color.secondary.opacity(0.18)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct TopologyEdgeCanvas: View {
    let graph: TopologyGraphLayout

    var body: some View {
        Canvas { context, _ in
            for edge in graph.edges {
                guard let source = graph.nodeByID[edge.source],
                      let target = graph.nodeByID[edge.target] else { continue }

                let sourcePosition = graph.position(for: source)
                let targetPosition = graph.position(for: target)
                let start = CGPoint(
                    x: sourcePosition.x + graph.size(for: source).width / 2,
                    y: sourcePosition.y
                )
                let end = CGPoint(
                    x: targetPosition.x - graph.size(for: target).width / 2,
                    y: targetPosition.y
                )
                let controlOffset = max((end.x - start.x) * 0.45, 40)

                var connector = Path()
                connector.move(to: start)
                connector.addCurve(
                    to: end,
                    control1: CGPoint(x: start.x + controlOffset, y: start.y),
                    control2: CGPoint(x: end.x - controlOffset, y: end.y)
                )
                context.stroke(
                    connector,
                    with: .color(Color.secondary.opacity(0.42)),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                )

                var arrow = Path()
                arrow.move(to: end)
                arrow.addLine(to: CGPoint(x: end.x - 9, y: end.y - 5))
                arrow.addLine(to: CGPoint(x: end.x - 9, y: end.y + 5))
                arrow.closeSubpath()
                context.fill(arrow, with: .color(Color.secondary.opacity(0.55)))
            }
        }
        .allowsHitTesting(false)
    }
}

private struct TopologyNodeCard: View {
    let node: TopologyNode
    let connections: [TopologyConnection]
    @Binding var selectedNode: TopologyNode?

    private var isNetwork: Bool { node.type == .network }

    private var accent: Color {
        guard !isNetwork else { return .teal }
        switch node.metadata.status?.lowercased() {
        case "running": return .green
        case "paused": return .orange
        case "exited", "dead": return .red
        default: return .secondary
        }
    }

    private var addressLines: [String] {
        guard !isNetwork else { return [] }
        let hasMultipleNetworks = connections.count > 1
        return connections.compactMap { connection -> String? in
            let addresses = [connection.ipv4Address, connection.ipv6Address]
                .compactMap { value -> String? in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
            guard !addresses.isEmpty else { return nil }
            let address = addresses.joined(separator: " | ")
            return hasMultipleNetworks ? "\(connection.otherNode.name): \(address)" : address
        }
    }

    var body: some View {
        Button {
            selectedNode = node
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: isNetwork ? "network" : "shippingbox.fill")
                        .font(.headline)
                        .foregroundStyle(accent)
                        .frame(width: 32, height: 32)
                        .background(accent.opacity(0.12), in: .circle)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.name.isEmpty ? node.id : node.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if isNetwork {
                            Text(networkSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else if let status = node.metadata.status, !status.isEmpty {
                            Text(status.capitalized)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(accent)
                                .lineLimit(1)
                        }
                    }

                    if node.metadata.isDefault == true {
                        Text("Default")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.teal)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.teal.opacity(0.12), in: .capsule)
                    }
                }

                if !isNetwork {
                    if let image = node.metadata.image, !image.isEmpty {
                        Label(image, systemImage: "opticaldisc")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    ForEach(Array(addressLines.prefix(2).enumerated()), id: \.offset) { _, line in
                        Label {
                            Text(verbatim: line)
                                .lineLimit(1)
                        } icon: {
                            Image(systemName: "number")
                        }
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    }
                    if addressLines.count > 2 {
                        Text(verbatim: "+\(addressLines.count - 2) more connections")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(.secondarySystemGroupedBackground))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.standard, style: .continuous)
                    .stroke(accent.opacity(0.55), lineWidth: 1)
            }
            .compositingGroup()
            .clipShape(.rect(cornerRadius: Radius.standard))
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Shows topology details")
    }

    private var networkSummary: String {
        [node.metadata.driver, node.metadata.scope]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value.capitalized
            }
            .joined(separator: " · ")
    }

    private var accessibilityDescription: String {
        var parts = [isNetwork ? "Network" : "Container", node.name.isEmpty ? node.id : node.name]
        if isNetwork {
            if !networkSummary.isEmpty { parts.append(networkSummary) }
            if node.metadata.isDefault == true { parts.append("Default network") }
        } else {
            if let status = node.metadata.status, !status.isEmpty { parts.append(status) }
            parts.append(contentsOf: addressLines)
        }
        return parts.joined(separator: ", ")
    }
}

private struct TopologyNodeDetailSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let node: TopologyNode
    let topology: NetworkTopology

    private var connections: [TopologyConnection] {
        TopologyGraphLayout.connections(for: node, in: topology)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Node") {
                    LabeledContent("Type", value: node.type == .network ? "Network" : "Container")
                    LabeledContent("Name", value: node.name.isEmpty ? "—" : node.name)
                    LabeledContent("ID") {
                        Text(verbatim: node.id)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                }

                metadataSection

                Section("Connections") {
                    if connections.isEmpty {
                        Text("No connected nodes")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(connections) { connection in
                            VStack(alignment: .leading, spacing: 6) {
                                Label(
                                    connection.otherNode.name.isEmpty
                                        ? connection.otherNode.id
                                        : connection.otherNode.name,
                                    systemImage: connection.otherNode.type == .network ? "network" : "shippingbox"
                                )
                                .font(.body.weight(.medium))

                                if let ipv4Address = connection.ipv4Address, !ipv4Address.isEmpty {
                                    LabeledContent("IPv4") {
                                        Text(verbatim: ipv4Address)
                                            .font(.caption.monospaced())
                                            .textSelection(.enabled)
                                    }
                                }
                                if let ipv6Address = connection.ipv6Address, !ipv6Address.isEmpty {
                                    LabeledContent("IPv6") {
                                        Text(verbatim: ipv6Address)
                                            .font(.caption.monospaced())
                                            .textSelection(.enabled)
                                    }
                                }
                                if connection.hasNoAddress {
                                    Text("No assigned IP address")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle(node.name.isEmpty ? "Topology Node" : node.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var metadataSection: some View {
        if node.type == .network {
            Section("Network Details") {
                if let driver = node.metadata.driver, !driver.isEmpty {
                    LabeledContent("Driver", value: driver)
                }
                if let scope = node.metadata.scope, !scope.isEmpty {
                    LabeledContent("Scope", value: scope.capitalized)
                }
                LabeledContent("Default", value: node.metadata.isDefault == true ? "Yes" : "No")
            }
        } else {
            Section("Container Details") {
                if let status = node.metadata.status, !status.isEmpty {
                    LabeledContent("Status", value: status.capitalized)
                }
                if let image = node.metadata.image, !image.isEmpty {
                    LabeledContent("Image") {
                        Text(image)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

private struct TopologyConnection: Identifiable, Hashable {
    let id: String
    let otherNode: TopologyNode
    let ipv4Address: String?
    let ipv6Address: String?

    var hasNoAddress: Bool {
        (ipv4Address?.isEmpty ?? true) && (ipv6Address?.isEmpty ?? true)
    }
}

private struct TopologyGraphLayout {
    private static let networkNodeSize = CGSize(width: 224, height: 112)
    private static let containerNodeSize = CGSize(width: 268, height: 164)
    private static let outerPadding: CGFloat = 36
    private static let columnGap: CGFloat = 180
    private static let rowGap: CGFloat = 28
    private static let groupGap: CGFloat = 72

    let nodes: [TopologyNode]
    let edges: [TopologyEdge]
    let nodeByID: [String: TopologyNode]
    let connectionsByNode: [String: [TopologyConnection]]
    let contentSize: CGSize

    private let positions: [String: CGPoint]

    init(topology: NetworkTopology) {
        var uniqueNodes: [TopologyNode] = []
        var resolvedNodes: [String: TopologyNode] = [:]
        for node in topology.nodes where resolvedNodes[node.id] == nil {
            uniqueNodes.append(node)
            resolvedNodes[node.id] = node
        }

        let networks = uniqueNodes
            .filter { $0.type == .network }
            .sorted(by: Self.nodeSort)
        let containers = uniqueNodes
            .filter { $0.type == .container }
            .sorted(by: Self.nodeSort)
        let networkOrder = Dictionary(uniqueKeysWithValues: networks.enumerated().map { ($1.id, $0) })

        var seenEdgeIDs: Set<String> = []
        let validEdges = topology.edges
            .filter { edge in
                guard seenEdgeIDs.insert(edge.id).inserted,
                      resolvedNodes[edge.source]?.type == .network,
                      resolvedNodes[edge.target]?.type == .container else { return false }
                return true
            }
            .sorted { left, right in
                let leftSourceOrder = networkOrder[left.source] ?? .max
                let rightSourceOrder = networkOrder[right.source] ?? .max
                if leftSourceOrder != rightSourceOrder {
                    return leftSourceOrder < rightSourceOrder
                }
                let leftTarget = resolvedNodes[left.target]
                let rightTarget = resolvedNodes[right.target]
                let comparison = (leftTarget?.name ?? "")
                    .localizedStandardCompare(rightTarget?.name ?? "")
                if comparison != .orderedSame { return comparison == .orderedAscending }
                if left.target != right.target { return left.target < right.target }
                return left.id < right.id
            }

        var containersByNetwork: [String: [TopologyNode]] = [:]
        var isolatedContainers: [TopologyNode] = []
        for container in containers {
            let primaryNetworkID = validEdges
                .filter { $0.target == container.id }
                .compactMap { edge -> (id: String, order: Int)? in
                    networkOrder[edge.source].map { (id: edge.source, order: $0) }
                }
                .min { $0.order < $1.order }?
                .id
            if let primaryNetworkID {
                containersByNetwork[primaryNetworkID, default: []].append(container)
            } else {
                isolatedContainers.append(container)
            }
        }
        for networkID in containersByNetwork.keys {
            containersByNetwork[networkID]?.sort(by: Self.nodeSort)
        }

        let networkX = Self.outerPadding + Self.networkNodeSize.width / 2
        let containerX = Self.outerPadding + Self.networkNodeSize.width
            + Self.columnGap + Self.containerNodeSize.width / 2
        var resolvedPositions: [String: CGPoint] = [:]
        var currentTop = Self.outerPadding

        for network in networks {
            let groupedContainers = containersByNetwork[network.id] ?? []
            let containerHeight = Self.columnHeight(
                count: groupedContainers.count,
                nodeHeight: Self.containerNodeSize.height
            )
            let groupHeight = max(Self.networkNodeSize.height, containerHeight)
            resolvedPositions[network.id] = CGPoint(
                x: networkX,
                y: currentTop + groupHeight / 2
            )
            for (index, container) in groupedContainers.enumerated() {
                resolvedPositions[container.id] = CGPoint(
                    x: containerX,
                    y: currentTop + Self.containerNodeSize.height / 2
                        + CGFloat(index) * (Self.containerNodeSize.height + Self.rowGap)
                )
            }
            currentTop += groupHeight + Self.groupGap
        }

        if !isolatedContainers.isEmpty {
            for (index, container) in isolatedContainers.enumerated() {
                resolvedPositions[container.id] = CGPoint(
                    x: containerX,
                    y: currentTop + Self.containerNodeSize.height / 2
                        + CGFloat(index) * (Self.containerNodeSize.height + Self.rowGap)
                )
            }
            currentTop += Self.columnHeight(
                count: isolatedContainers.count,
                nodeHeight: Self.containerNodeSize.height
            ) + Self.groupGap
        }

        let minimumHeight = max(Self.networkNodeSize.height, Self.containerNodeSize.height)
        let contentHeight = max(currentTop - Self.groupGap + Self.outerPadding, minimumHeight + Self.outerPadding * 2)
        positions = resolvedPositions
        contentSize = CGSize(
            width: Self.outerPadding * 2 + Self.networkNodeSize.width
                + Self.columnGap + Self.containerNodeSize.width,
            height: contentHeight
        )
        nodes = networks + containers
        edges = validEdges
        nodeByID = resolvedNodes

        var resolvedConnections: [String: [TopologyConnection]] = [:]
        for node in nodes {
            resolvedConnections[node.id] = Self.connections(
                for: node,
                edges: validEdges,
                nodeByID: resolvedNodes
            )
        }
        connectionsByNode = resolvedConnections
    }

    func position(for node: TopologyNode) -> CGPoint {
        positions[node.id] ?? CGPoint(x: contentSize.width / 2, y: contentSize.height / 2)
    }

    func size(for node: TopologyNode) -> CGSize {
        node.type == .network ? Self.networkNodeSize : Self.containerNodeSize
    }

    static func connections(for node: TopologyNode, in topology: NetworkTopology) -> [TopologyConnection] {
        var nodeByID: [String: TopologyNode] = [:]
        for candidate in topology.nodes where nodeByID[candidate.id] == nil {
            nodeByID[candidate.id] = candidate
        }
        var seenEdgeIDs: Set<String> = []
        let validEdges = topology.edges.filter { edge in
            seenEdgeIDs.insert(edge.id).inserted
                && nodeByID[edge.source]?.type == .network
                && nodeByID[edge.target]?.type == .container
        }
        return connections(for: node, edges: validEdges, nodeByID: nodeByID)
    }

    private static func connections(
        for node: TopologyNode,
        edges: [TopologyEdge],
        nodeByID: [String: TopologyNode]
    ) -> [TopologyConnection] {
        let matchingEdges = edges.filter { edge in
            node.type == .network ? edge.source == node.id : edge.target == node.id
        }
        return matchingEdges.enumerated().compactMap { index, edge -> TopologyConnection? in
            let otherID = node.type == .network ? edge.target : edge.source
            guard let otherNode = nodeByID[otherID] else { return nil }
            return TopologyConnection(
                id: "\(edge.id)#\(index)",
                otherNode: otherNode,
                ipv4Address: edge.ipv4Address,
                ipv6Address: edge.ipv6Address
            )
        }
        .sorted {
            let comparison = $0.otherNode.name.localizedStandardCompare($1.otherNode.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return $0.id < $1.id
        }
    }

    private static func nodeSort(_ left: TopologyNode, _ right: TopologyNode) -> Bool {
        let comparison = left.name.localizedStandardCompare(right.name)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return left.id < right.id
    }

    private static func columnHeight(count: Int, nodeHeight: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * nodeHeight + CGFloat(count - 1) * rowGap
    }
}
