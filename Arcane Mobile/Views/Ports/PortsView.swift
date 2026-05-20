import SwiftUI
import Arcane

struct PortsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let environmentID: EnvironmentID

    @State private var ports: [PortMapping] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""

    private var grouped: [(container: String, ports: [PortMapping])] {
        let filtered = filteredPorts
        let groups = Dictionary(grouping: filtered) { $0.containerName }
        return groups
            .map { (container: $0.key, ports: $0.value.sorted { lhs, rhs in
                let lhsHost = lhs.hostPort ?? Int.max
                let rhsHost = rhs.hostPort ?? Int.max
                if lhsHost != rhsHost { return lhsHost < rhsHost }
                return lhs.containerPort < rhs.containerPort
            }) }
            .sorted { $0.container.localizedStandardCompare($1.container) == .orderedAscending }
    }

    private var filteredPorts: [PortMapping] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ports }
        return ports.filter { port in
            port.containerName.localizedCaseInsensitiveContains(trimmed) ||
            port.protocolName.localizedCaseInsensitiveContains(trimmed) ||
            portString(port.containerPort).contains(trimmed) ||
            (port.hostPort.map(portString) ?? "").contains(trimmed) ||
            (port.hostIp ?? "").localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        Group {
            if isLoading && ports.isEmpty {
                ProgressView("Loading ports…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, ports.isEmpty {
                ContentUnavailableView("Couldn't Load Ports", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if ports.isEmpty {
                ContentUnavailableView("No Ports", systemImage: "point.3.connected.trianglepath.dotted")
            } else {
                List {
                    ForEach(grouped, id: \.container) { group in
                        Section {
                            ForEach(group.ports) { port in
                                NavigationLink {
                                    PortMappingDetailView(port: port)
                                } label: {
                                    PortMappingRow(port: port)
                                }
                            }
                        } header: {
                            HStack(spacing: 8) {
                                Image(systemName: "shippingbox.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.blue)
                                Text(group.container)
                                    .font(.caption.weight(.semibold))
                                Text("(\(group.ports.count))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Ports")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search ports")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { Task { await load(refresh: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh")
                .disabled(isLoading)
            }
        }
        .task { await load() }
        .refreshable { await load(refresh: true) }
    }

    private func load(refresh: Bool = false) async {
        guard let client = manager.client else { return }
        if ports.isEmpty { isLoading = true }
        if refresh { errorMessage = nil }
        defer { isLoading = false }
        do {
            // The list endpoint paginates; surface the full set in one shot.
            let response = try await client.ports.list(
                envID: environmentID,
                query: .init(start: 0, limit: 500)
            )
            ports = response.data
            errorMessage = nil
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

private struct PortMappingRow: View {
    let port: PortMapping

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: port.isPublished ? "arrow.left.arrow.right.circle.fill" : "lock.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(port.isPublished ? .green : .gray)
                .frame(width: 28, height: 28)
                .background((port.isPublished ? Color.green : .gray).opacity(0.15), in: .circle)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if port.hostPort != nil {
                        Text(hostString(port))
                            .font(.subheadline.weight(.semibold).monospaced())
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(portString(port.containerPort))
                            .font(.subheadline.weight(.semibold).monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        Text(portString(port.containerPort))
                            .font(.subheadline.weight(.semibold).monospaced())
                        Text("(internal)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(port.protocolName.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(protocolTint)
            }

            Spacer(minLength: 8)

            if port.isPublished {
                Text("PUB")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.green.opacity(0.15), in: .capsule)
            }
        }
        .padding(.vertical, 2)
    }

    private func hostString(_ port: PortMapping) -> String {
        let ip = port.hostIp.flatMap { $0.isEmpty ? nil : $0 } ?? "0.0.0.0"
        guard let hostPort = port.hostPort else { return ip }
        return "\(ip):\(portString(hostPort))"
    }

    private var protocolTint: Color {
        switch port.protocolName.lowercased() {
        case "tcp": return .blue
        case "udp": return .purple
        case "sctp": return .pink
        default: return .gray
        }
    }
}

private struct PortMappingDetailView: View {
    let port: PortMapping

    var body: some View {
        List {
            Section("Mapping") {
                if let hostPort = port.hostPort {
                    LabeledContent("Host") {
                        Text(hostString)
                            .font(.subheadline.monospaced())
                            .textSelection(.enabled)
                    }
                    LabeledContent("Host Port", value: portString(hostPort))
                } else {
                    LabeledContent("Exposure", value: "Internal only")
                }
                LabeledContent("Container Port", value: portString(port.containerPort))
                LabeledContent("Protocol", value: port.protocolName.uppercased())
                LabeledContent("Published", value: port.isPublished ? "Yes" : "No")
            }

            Section("Container") {
                LabeledContent("Name", value: port.containerName)
                LabeledContent("ID") {
                    Text(port.containerId)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle(port.containerName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hostString: String {
        let ip = port.hostIp.flatMap { $0.isEmpty ? nil : $0 } ?? "0.0.0.0"
        guard let hostPort = port.hostPort else { return ip }
        return "\(ip):\(portString(hostPort))"
    }
}

private func portString<T: BinaryInteger>(_ value: T) -> String {
    String(value)
}
