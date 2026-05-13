import SwiftUI
import Arcane

struct NetworksView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    let environmentID: EnvironmentID
    let environmentName: String

    @State private var networks: [NetworkInfo] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var actionErrorMessage: String?
    @State private var searchText = ""
    @State private var showCreateSheet = false
    @State private var showPruneConfirm = false
    @State private var showFilterSheet = false
    @State private var typeFilter = NetworkTypeFilter.all
    @State private var sortOrder = ListSortOrder.ascending

    private enum NetworkTypeFilter: String, CaseIterable {
        case all = "All", standard = "Standard", internalOnly = "Internal"
    }

    private var activeFilterCount: Int { typeFilter != .all ? 1 : 0 }

    private var mutationVersion: Int {
        mutationStore.version(kind: .networks, envID: environmentID)
    }

    private static let systemNetworkNames: Set<String> = ["host", "bridge", "none"]

    private static func isSystem(_ network: NetworkInfo) -> Bool {
        systemNetworkNames.contains(network.name.lowercased())
    }

    private var filtered: [NetworkInfo] {
        networks.filter { network in
            let matchesSearch = searchText.isEmpty ||
                network.name.localizedCaseInsensitiveContains(searchText) ||
                network.driver.localizedCaseInsensitiveContains(searchText)
            let matchesType = typeFilter == .all
                || (typeFilter == .standard && !network.isInternal)
                || (typeFilter == .internalOnly && network.isInternal)
            return matchesSearch && matchesType
        }
        .sorted {
            sortOrder.areInIncreasingOrder($0.name, $1.name)
        }
    }

    private var systemNetworks: [NetworkInfo] {
        filtered.filter { Self.isSystem($0) }
    }

    private var userNetworks: [NetworkInfo] {
        filtered.filter { !Self.isSystem($0) }
    }

    var body: some View {
        Group {
            if isLoading && networks.isEmpty {
                ProgressView("Loading networks...").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage, networks.isEmpty {
                ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if networks.isEmpty {
                ContentUnavailableView("No Networks", systemImage: "network", description: Text("No networks found"))
            } else {
                List {
                    if !systemNetworks.isEmpty {
                        Section {
                            ForEach(systemNetworks) { network in
                                NavigationLink(destination: NetworkDetailView(network: network, environmentID: environmentID)) {
                                    NetworkRow(network: network)
                                }
                                .contextMenu {
                                    // No actions — built-in Docker networks cannot be deleted.
                                } preview: {
                                    networkPreview(network)
                                }
                            }
                        } header: {
                            Text("Built-in")
                        } footer: {
                            Text("Built-in Docker networks can't be removed.")
                        }
                    }
                    if !userNetworks.isEmpty {
                        Section(systemNetworks.isEmpty ? "" : "Custom") {
                            ForEach(userNetworks) { network in
                                NavigationLink(destination: NetworkDetailView(network: network, environmentID: environmentID)) {
                                    NetworkRow(network: network)
                                }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        Task { await deleteNetwork(network) }
                                    } label: {
                                        DestructiveLabel(text: "Delete")
                                    }
                                    .tint(.red)
                                } preview: {
                                    networkPreview(network)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        Task { await deleteNetwork(network) }
                                    } label: {
                                        DestructiveLabel(text: "Delete")
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Networks")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search networks")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(ListSortOrder.allCases) { order in
                            Label(order.title, systemImage: order.systemImage).tag(order)
                        }
                    }
                    Button {
                        showFilterSheet = true
                    } label: {
                        Label(activeFilterCount > 0 ? "Filter (\(activeFilterCount))" : "Filter…", systemImage: "line.3.horizontal.decrease.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More options")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showCreateSheet = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create network")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showPruneConfirm = true } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Prune unused networks")
            }
        }
        .task { await loadNetworks() }
        .refreshable { await loadNetworks(refresh: true) }
        .sheet(isPresented: $showCreateSheet) {
            CreateNetworkView(environmentID: environmentID) {}
        }
        .alert("Prune Networks", isPresented: $showPruneConfirm) {
            Button("Prune", role: .destructive) { Task { await pruneNetworks() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove all unused networks.")
        }
        .alert(
            "Action Failed",
            isPresented: Binding(
                get: { actionErrorMessage != nil },
                set: { if !$0 { actionErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { actionErrorMessage = nil }
        } message: {
            Text(actionErrorMessage ?? "")
        }
        .sheet(isPresented: $showFilterSheet) {
            NavigationStack {
                Form {
                    Section("Type") {
                        Picker("Type", selection: $typeFilter) {
                            ForEach(NetworkTypeFilter.allCases, id: \.self) { f in
                                Text(f.rawValue).tag(f)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
                .navigationTitle("Filter")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showFilterSheet = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .onChange(of: mutationVersion) { _, _ in
            Task { await loadNetworks(refresh: true) }
        }
    }

    private func networkPreview(_ network: NetworkInfo) -> some View {
        var badges: [RowPreviewCard.PreviewBadge] = [
            .init(text: network.driver.capitalized, color: .teal)
        ]
        if network.isInternal {
            badges.append(.init(text: "Internal", color: .orange))
        }
        var details: [RowPreviewCard.PreviewDetail] = [
            .init(icon: "globe", label: "Scope", value: network.scope.capitalized)
        ]
        if network.containerCount > 0 {
            details.insert(.init(
                icon: "shippingbox",
                label: "Connected Containers",
                value: "\(network.containerCount)"
            ), at: 0)
        }
        details.append(.init(icon: "number", label: "ID", value: network.id, monospaced: true))
        return RowPreviewCard(
            icon: "network",
            iconColor: .teal,
            title: network.name.isEmpty ? network.id : network.name,
            badges: badges,
            details: details
        )
    }

    private func loadNetworks(refresh: Bool = false) async {
        guard let client = manager.client, let cached = manager.cached else { return }
        if networks.isEmpty { isLoading = true }
        errorMessage = nil
        defer { isLoading = false }
        do {
            let path = client.rest.environmentPath(environmentID, "networks")
            if let result: [NetworkInfo] = try await cached.getList(
                path, elementType: NetworkInfo.self, policy: .networks,
                envID: environmentID, refresh: refresh,
                onFresh: { fresh in networks = fresh }
            ) {
                networks = result
            }
        } catch { errorMessage = friendlyErrorMessage(error) }
    }

    private func deleteNetwork(_ network: NetworkInfo) async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "networks/\(network.id)")
            let _: DataResponse<String> = try await client.rest.delete(path)
            withAnimation {
                networks.removeAll { $0.id == network.id }
            }
            await invalidateNetworkCaches()
            mutationStore.markChanged(kind: .networks, envID: environmentID)
        } catch {
            actionErrorMessage = friendlyErrorMessage(error)
        }
    }

    private func pruneNetworks() async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "networks/prune")
            let _: DataResponse<String> = try await client.rest.post(path, body: String?.none)
            await invalidateNetworkCaches()
            mutationStore.markChanged(kind: .networks, envID: environmentID)
        } catch {
            actionErrorMessage = friendlyErrorMessage(error)
        }
    }

    private func invalidateNetworkCaches() async {
        guard let cached = manager.cached, let client = manager.client else { return }
        await cached.invalidate(envID: environmentID, paths: [
            client.rest.environmentPath(environmentID, "networks"),
            client.rest.environmentPath(environmentID, "networks/*")
        ])
    }
}

struct NetworkRow: View {
    let network: NetworkInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "network")
                .font(.title3)
                .foregroundStyle(.teal)
                .frame(width: 36, height: 36)
                .glassEffect(.regular, in: .circle)

            VStack(alignment: .leading, spacing: 3) {
                Text(network.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(network.driver)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if network.isInternal {
                        Text("• Internal").font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            Spacer()

            if network.containerCount > 0 {
                Text("\(network.containerCount)")
                    .font(.caption.bold())
                    .foregroundStyle(.teal)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
            }
        }
        .padding(.vertical, 2)
    }
}

struct NetworkDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let network: NetworkInfo
    let environmentID: EnvironmentID

    @State private var inspect: NetworkInspect?
    @State private var isLoadingInspect = false
    @State private var inspectError: String?
    @State private var showDeleteConfirm = false
    @State private var errorMessage: String?

    private var isBuiltIn: Bool {
        ["host", "bridge", "none"].contains(network.name.lowercased())
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "network")
                        .font(.title)
                        .foregroundStyle(.teal)
                        .frame(width: 56, height: 56)
                        .glassEffect(.regular, in: .circle)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(network.name).font(.title3.bold())
                        Text(network.driver).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Details") {
                LabeledContent("ID", value: String(network.id.prefix(12)))
                LabeledContent("Driver", value: network.driver)
                LabeledContent("Scope", value: network.scope.capitalized)
                if let inspect {
                    if inspect._internal { LabeledContent("Internal", value: "Yes") }
                    LabeledContent("Attachable", value: inspect.attachable ? "Yes" : "No")
                    LabeledContent("IPv4", value: inspect.enableIPv4 ? "Enabled" : "Disabled")
                    LabeledContent("IPv6", value: inspect.enableIPv6 ? "Enabled" : "Disabled")
                }
                NavigationLink("Topology") {
                    NetworkTopologyView(environmentID: environmentID)
                }
            }

            if let ipam = inspect?.ipam {
                Section("IPAM") {
                    if let driver = ipam.driver, !driver.isEmpty {
                        LabeledContent("Driver", value: driver)
                    }
                    ForEach(Array((ipam.config ?? []).enumerated()), id: \.offset) { _, config in
                        if let subnet = config.subnet, !subnet.isEmpty {
                            LabeledContent("Subnet") {
                                Text(subnet).font(.body.monospaced())
                            }
                        }
                        if let gw = config.gateway, !gw.isEmpty {
                            LabeledContent("Gateway") {
                                Text(gw).font(.body.monospaced())
                            }
                        }
                        if let range = config.ipRange, !range.isEmpty {
                            LabeledContent("IP Range") {
                                Text(range).font(.body.monospaced())
                            }
                        }
                    }
                }
            }

            connectedContainersSection

            if isLoadingInspect && inspect == nil {
                Section {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Loading network details…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let inspectError, inspect == nil {
                Section {
                    Label(inspectError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(network.name.isEmpty ? network.id : network.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isBuiltIn {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .task { await loadInspect() }
        .refreshable { await loadInspect() }
        .confirmationDialog("Delete Network", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                Task { await deleteNetwork() }
            }
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var connectedContainersSection: some View {
        if let endpoints = inspect?.containersList, !endpoints.isEmpty {
            Section("Connected Containers (\(endpoints.count))") {
                ForEach(endpoints, id: \.id) { endpoint in
                    NetworkContainerRow(endpoint: endpoint)
                }
            }
        } else if let containers = inspect?.containers.additionalProperties, !containers.isEmpty {
            let sortedKeys = Array(containers.keys.sorted())
            Section("Connected Containers (\(sortedKeys.count))") {
                ForEach(sortedKeys, id: \.self) { key in
                    if let endpoint = containers[key] {
                        NetworkContainerRow(
                            id: key,
                            name: endpoint.name,
                            ipv4: endpoint.iPv4Address,
                            ipv6: endpoint.iPv6Address
                        )
                    }
                }
            }
        }
    }

    private func loadInspect() async {
        guard let client = manager.client else { return }
        if inspect == nil { isLoadingInspect = true }
        defer { isLoadingInspect = false }
        do {
            let path = client.rest.environmentPath(environmentID, "networks/\(network.id)")
            let result: NetworkInspect = try await client.rest.get(path)
            inspect = result
            inspectError = nil
        } catch {
            inspectError = friendlyErrorMessage(error)
        }
    }

    private func deleteNetwork() async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "networks/\(network.id)")
            let _: DataResponse<String> = try await client.rest.delete(path)
            if let cached = manager.cached {
                await cached.invalidate(envID: environmentID, paths: [
                    client.rest.environmentPath(environmentID, "networks"),
                    client.rest.environmentPath(environmentID, "networks/*")
                ])
            }
            mutationStore.markChanged(kind: .networks, envID: environmentID)
            dismiss()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

struct CreateNetworkView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let environmentID: EnvironmentID
    let onSuccess: () async -> Void

    @State private var name = ""
    @State private var driver = "bridge"
    @State private var isInternal = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Network Details") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Driver", selection: $driver) {
                        Text("Bridge").tag("bridge")
                        Text("Host").tag("host")
                        Text("Overlay").tag("overlay")
                        Text("Macvlan").tag("macvlan")
                        Text("None").tag("none")
                    }
                    Toggle("Internal", isOn: $isInternal)
                }
                if let error = errorMessage {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Create Network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await createNetwork() } }
                        .disabled(name.isEmpty || isLoading)
                }
            }
        }
    }

    private func createNetwork() async {
        guard let client = manager.client else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let body: [String: AnyCodable] = [
                "name": AnyCodable(name),
                "driver": AnyCodable(driver),
                "internal": AnyCodable(isInternal)
            ]
            let path = client.rest.environmentPath(environmentID, "networks")
            let _: NetworkInfo = try await client.rest.post(path, body: body)
            if let cached = manager.cached {
                await cached.invalidate(envID: environmentID, paths: [
                    client.rest.environmentPath(environmentID, "networks"),
                    client.rest.environmentPath(environmentID, "networks/*")
                ])
            }
            mutationStore.markChanged(kind: .networks, envID: environmentID)
            await onSuccess(); dismiss()
        } catch { errorMessage = friendlyErrorMessage(error) }
    }
}

private struct NetworkContainerRow: View {
    let id: String
    let name: String?
    let ipv4: String?
    let ipv6: String?

    init(id: String, name: String?, ipv4: String?, ipv6: String?) {
        self.id = id
        self.name = name
        self.ipv4 = ipv4
        self.ipv6 = ipv6
    }

    init(endpoint: NetworkContainerEndpoint) {
        self.id = endpoint.id
        self.name = endpoint.name
        self.ipv4 = endpoint.ipv4Address
        self.ipv6 = endpoint.ipv6Address
    }

    private var displayName: String {
        let trimmed = (name ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return trimmed.isEmpty ? String(id.prefix(12)) : trimmed
    }

    private var displayIP: String {
        if let v4 = ipv4, !v4.isEmpty { return v4 }
        if let v6 = ipv6, !v6.isEmpty { return v6 }
        return "—"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(displayIP)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}
