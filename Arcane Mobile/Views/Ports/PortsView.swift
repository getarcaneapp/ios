import Arcane
import SwiftUI

struct PortsView: View {
    private static let pageSize = 50

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(EnvironmentsStore.self) private var environmentsStore
    let environmentID: EnvironmentID
    /// All Environments preview: list and act on resources from every enabled environment.
    var allEnvironments = false

    @State private var list = EnvironmentPagedList<PortMapping>(pageSize: Self.pageSize)
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    // Filtered + grouped result cached here so body doesn't re-run the
    // filter/group/sort pipeline on every evaluation (see rebuildSections()).
    @State private var sections: [PortGroup] = []

    private var ports: [EnvironmentItem<PortMapping>] { list.items }

    /// One group per container. In All Environments lists the same container
    /// name in two environments stays two groups.
    private struct PortGroup: Identifiable {
        let container: String
        let environmentID: EnvironmentID
        let environmentName: String?
        let ports: [EnvironmentItem<PortMapping>]
        var id: String { environmentName == nil ? container : "\(environmentID.rawValue)/\(container)" }
    }

    private struct GroupKey: Hashable {
        let environmentID: EnvironmentID
        let container: String
    }

    private func rebuildSections() {
        let filtered = filteredPorts(matching: debouncedSearchText)
        let groups = Dictionary(grouping: filtered) {
            GroupKey(environmentID: $0.environmentID, container: $0.containerName)
        }
        sections =
            groups
            .map {
                PortGroup(
                    container: $0.key.container,
                    environmentID: $0.key.environmentID,
                    environmentName: $0.value.first?.environmentName,
                    ports: $0.value.sorted { lhs, rhs in
                        let lhsHost = lhs.hostPort ?? Int.max
                        let rhsHost = rhs.hostPort ?? Int.max
                        if lhsHost != rhsHost { return lhsHost < rhsHost }
                        return lhs.containerPort < rhs.containerPort
                    })
            }
            .sorted {
                let order = $0.container.localizedStandardCompare($1.container)
                guard order == .orderedSame else { return order == .orderedAscending }
                return ($0.environmentName ?? "").localizedStandardCompare($1.environmentName ?? "")
                    == .orderedAscending
            }
    }

    private func filteredPorts(matching query: String) -> [EnvironmentItem<PortMapping>] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ports }
        return ports.filter { port in
            port.containerName.localizedCaseInsensitiveContains(trimmed)
                || port.protocolName.localizedCaseInsensitiveContains(trimmed)
                || portString(port.containerPort).contains(trimmed)
                || (port.hostPort.map(portString) ?? "").contains(trimmed)
                || displayHostIP(port.hostIp).localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        Group {
            if list.isLoading && ports.isEmpty {
                ArcaneLoadingView("Loading ports…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = list.errorMessage, ports.isEmpty {
                ContentUnavailableView(
                    "Couldn't Load Ports", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if ports.isEmpty {
                ContentUnavailableView("No Ports", systemImage: "point.3.connected.trianglepath.dotted")
            } else {
                List {
                    EnvironmentLoadFailuresSection(failures: list.failedEnvironments) {
                        Task { await load() }
                    }
                    ForEach(sections) { group in
                        Section {
                            ForEach(group.ports) { port in
                                NavigationLink {
                                    PortMappingDetailView(port: port.value)
                                } label: {
                                    PortMappingRow(port: port.value, environmentName: port.environmentName)
                                        .rowEnvironment(port)
                                }
                            }
                        } header: {
                            HStack(spacing: 8) {
                                Image(systemName: "shippingbox.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.blue)
                                Text(group.container)
                                    .font(.caption.weight(.semibold))
                                Text(verbatim: "(\(group.ports.count))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Spacer(minLength: 8)
                                if group.id == sections.first?.id {
                                    ResourceCountLabel(
                                        loadedCount: ports.count,
                                        totalCount: list.totalItems,
                                        hasMore: list.hasMore
                                    )
                                }
                            }
                            .textCase(nil)
                        }
                    }

                    if list.hasMore {
                        if list.loadMoreError != nil {
                            Button("Retry loading more") {
                                Task { await loadMore() }
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            ArcaneLoadingView("Loading more…", style: .inline).frame(maxWidth: .infinity)
                                .onAppear {
                                    Task { await loadMore() }
                                }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Ports")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search ports")
        .debounce(searchText, for: .milliseconds(200), into: $debouncedSearchText)
        .onChange(of: debouncedSearchText) {
            Task { await load() }
        }
        .toolbar {
            AppToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh")
                .disabled(list.isLoading)
            }
        }
        // Reappearing (back from a detail) refreshes every loaded page in
        // place; the first appear loads page one.
        .task { await load(preservingLoadedRange: true) }
        .refreshable { await load() }
        .onChange(of: list.revision) { rebuildSections() }
    }

    private func load(preservingLoadedRange: Bool = false) async {
        guard let client = manager.client else { return }
        let environments = await environmentsStore.listEnvironments(
            environmentID, allEnvironments: allEnvironments, manager: manager)
        await list.reload(
            environments, preservingLoadedRange: preservingLoadedRange, fetch: portsPage(client: client))
        rebuildSections()
    }

    private func loadMore() async {
        guard let client = manager.client else { return }
        await list.loadMore(fetch: portsPage(client: client))
        rebuildSections()
    }

    private func portsPage(client: ArcaneClient) -> EnvironmentPagedList<PortMapping>.Fetch {
        let search = debouncedSearchText.isEmpty ? nil : debouncedSearchText
        return { environmentID, start, limit in
            let response = try await client.ports.list(
                envID: environmentID,
                query: .init(search: search, start: start, limit: limit)
            )
            return ResourcePage(items: response.data, pagination: response.pagination)
        }
    }
}

struct PortMappingRow: View {
    let port: PortMapping

    var environmentName: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            RowIcon(systemImage: port.isPublished ? "arrow.left.arrow.right" : "lock.fill", tint: port.isPublished ? .green : .gray)

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
                EnvironmentLabel(name: environmentName)
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
        let ip = displayHostIP(port.hostIp)
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

struct PortMappingDetailView: View {
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
        let ip = displayHostIP(port.hostIp)
        guard let hostPort = port.hostPort else { return ip }
        return "\(ip):\(portString(hostPort))"
    }
}

private func displayHostIP(_ value: String?) -> String {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty,
        trimmed.localizedCaseInsensitiveCompare("invalid IP") != .orderedSame
    else {
        return "0.0.0.0"
    }
    return trimmed
}

private func portString<T: BinaryInteger>(_ value: T) -> String {
    String(value)
}
