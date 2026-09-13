import SwiftUI
import Arcane

struct NetworksView: View {
    private static let pageSize = 50

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    let environmentID: EnvironmentID
    let environmentName: String


    @State private var networks: [NetworkSummary] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var actionErrorMessage: String?
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var showCreateSheet = false
    @State private var pendingDestructive: NetworkDestructive?
    @State private var showFilterSheet = false
    @State private var typeFilter = NetworkTypeFilter.all
    @State private var sortOrder = ListSortOrder.ascending
    @State private var currentPage = 1
    @State private var hasMore = false
    @State private var totalItemCount: Int64?
    @State private var isLoadingMore = false
    @State private var loadMoreError: String?
    @State private var loadGeneration = 0
    @State private var systemNetworks: [NetworkSummary] = []
    @State private var userNetworks: [NetworkSummary] = []


    private enum NetworkTypeFilter: String, CaseIterable {
        case all = "All", standard = "Standard", internalOnly = "Internal"
    }

    /// Both destructive confirmations on this screen route through a single
    /// `.deleteConfirmation` cover (one full-screen cover per view).
    private enum NetworkDestructive {
        case prune
        case delete(NetworkSummary)
    }

    private var activeFilterCount: Int { typeFilter != .all ? 1 : 0 }

    private var mutationVersion: Int {
        mutationStore.version(kind: .networks, envID: environmentID)
    }

    private static let systemNetworkNames: Set<String> = ["host", "bridge", "none"]

    private static func isSystem(_ network: NetworkSummary) -> Bool {
        systemNetworkNames.contains(network.name.lowercased())
    }

    /// Filters + sorts once and partitions in a single pass into built-in vs
    /// custom networks. Pure — reads current inputs, returns the two groups.
    private func computePartition() -> (system: [NetworkSummary], user: [NetworkSummary]) {
        let query = debouncedSearchText
        let filtered = networks.filter { network in
            let matchesSearch = query.isEmpty ||
                network.name.localizedCaseInsensitiveContains(query) ||
                network.driver.localizedCaseInsensitiveContains(query)
            let matchesType = typeFilter == .all
                || (typeFilter == .standard && !network.isInternal)
                || (typeFilter == .internalOnly && network.isInternal)
            return matchesSearch && matchesType
        }
        .sorted {
            sortOrder.areInIncreasingOrder($0.name, $1.name)
        }
        var system: [NetworkSummary] = []
        var user: [NetworkSummary] = []
        for network in filtered {
            if Self.isSystem(network) { system.append(network) } else { user.append(network) }
        }
        return (system, user)
    }

    /// Refresh the cached partition. Called only when an input that affects
    /// grouping actually changes (search settle, sort, filter, or the source
    /// list) — never on every body evaluation.
    private func rebuildSections() {
        let (system, user) = computePartition()
        systemNetworks = system
        userNetworks = user
    }

    /// Section item counts — drives the List's implicit reflow animation so a
    /// programmatic insert/remove (delete/prune) animates too.

    var body: some View {
        LoadingCrossfade(
            showSkeleton: isLoading && networks.isEmpty,
            animatesTransition: false
        ) {
            ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } content: {
            if let error = errorMessage, networks.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't Load Networks", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await loadNetworks(reset: true) } }
                }
            } else if networks.isEmpty {
                ContentUnavailableView {
                    Label("No Networks", systemImage: "network")
                } description: {
                    Text("No networks found in this environment.")
                } actions: {
                    Button("Create Network") { showCreateSheet = true }
                }
            } else {
                List {
                    if !systemNetworks.isEmpty {
                        Section {
                            ForEach(systemNetworks) { network in
                                NavigationLink(value: network) {
                                    NetworkRow(network: network)
                                }
                                .contextMenu {
                                    // No actions — built-in Docker networks cannot be deleted.
                                } preview: {
                                    networkPreview(network)
                                        .environment(manager)
                                }
                            }
                        } header: {
                            ResourceCountSectionHeader(
                                "Built-in",
                                loadedCount: networks.count,
                                totalCount: totalItemCount,
                                hasMore: hasMore
                            )
                        } footer: {
                            Text("Built-in Docker networks can't be removed.")
                        }
                    }
                    if !userNetworks.isEmpty {
                        Section {
                            ForEach(userNetworks) { network in
                                NavigationLink(value: network) {
                                    NetworkRow(network: network)
                                }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        pendingDestructive = .delete(network)
                                    } label: {
                                        DestructiveLabel(text: "Delete")
                                    }
                                    .tint(.red)
                                } preview: {
                                    networkPreview(network)
                                        .environment(manager)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button {
                                        pendingDestructive = .delete(network)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .tint(.red)
                                }
                            }
                        } header: {
                            if systemNetworks.isEmpty {
                                ResourceCountSectionHeader(
                                    "Custom",
                                    loadedCount: networks.count,
                                    totalCount: totalItemCount,
                                    hasMore: hasMore
                                )
                            } else {
                                Text("Custom")
                            }
                        }
                    }
                    PaginatedListFooter(
                        hasMore: hasMore,
                        loadMoreError: loadMoreError,
                        onRetry: { Task { await loadMore() } },
                        onLoadMore: { Task { await loadMore() } }
                    )
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
                        .appAccentToolbarSymbol()
                }
                .accessibilityLabel("More options")
            }
            if #available(iOS 26, *) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showCreateSheet = true } label: {
                    Image(systemName: "plus")
                        .appAccentToolbarSymbol()
                }
                .accessibilityLabel("Create network")
            }
            if #available(iOS 26, *) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(role: .destructive) { pendingDestructive = .prune } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .accessibilityLabel("Prune unused networks")
            }
        }
        .task { await loadNetworks(reset: true) }
        .refreshable { await loadNetworks(reset: true, refresh: true) }
        .debounce(searchText, for: .milliseconds(200), into: $debouncedSearchText)
        .navigationDestination(for: NetworkSummary.self) { network in
            NetworkDetailView(network: network, environmentID: environmentID)
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateNetworkView(environmentID: environmentID) {}
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .deleteConfirmation(item: $pendingDestructive) { action in
            switch action {
            case .prune:
                return DeleteConfirmationConfig(
                    title: "Prune Networks",
                    message: "Remove all unused networks.",
                    icon: "trash",
                    actions: [DeleteConfirmationAction(title: "Prune") {
                        Task { await pruneNetworks() }
                    }]
                )
            case .delete(let network):
                return DeleteConfirmationConfig(
                    title: "Delete Network",
                    message: "Delete “\(network.name)”? This cannot be undone.",
                    icon: "trash",
                    actions: [DeleteConfirmationAction(title: "Delete") {
                        Task { await deleteNetwork(network) }
                    }]
                )
            }
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
            .presentationDragIndicator(.visible)
        }
        .onChange(of: mutationVersion) { _, _ in
            Task { await loadNetworks(reset: true, refresh: true) }
        }
        .onChange(of: debouncedSearchText) { rebuildSections() }
        .onChange(of: typeFilter) { rebuildSections() }
        .onChange(of: sortOrder) { rebuildSections() }
    }

    private func networkPreview(_ network: NetworkSummary) -> some View {
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

    private func loadNetworks(reset: Bool, refresh: Bool = false) async {
        guard let client = manager.client else { return }
        loadGeneration += 1
        let generation = loadGeneration
        let requestedPage = reset ? 1 : currentPage + 1
        let start = max(0, (requestedPage - 1) * Self.pageSize)
        if networks.isEmpty { isLoading = true }
        errorMessage = nil
        loadMoreError = nil
        defer {
            if loadGeneration == generation {
                isLoading = false
            }
        }
        do {
            // `PaginatedResponse<NetworkSummary>` is Decodable-only and can't
            // pass through the cache (Codable). Fetch directly.
            let response = try await client.networks.list(
                envID: environmentID,
                query: .init(start: start, limit: Self.pageSize)
            )
            applyNetworksPage(response, reset: reset, generation: generation)
        } catch {
            guard loadGeneration == generation else { return }
            if reset { errorMessage = friendlyErrorMessage(error) }
            else { loadMoreError = friendlyErrorMessage(error) }
        }
    }

    private func applyNetworksPage(_ response: PaginatedResponse<NetworkSummary>, reset: Bool, generation: Int) {
        guard loadGeneration == generation else { return }
        if reset {
            networks = response.data
        } else {
            let existing = Set(networks.map(\.id))
            networks.append(contentsOf: response.data.filter { !existing.contains($0.id) })
        }
        currentPage = max(Int(response.pagination.currentPage), 1)
        hasMore = response.pagination.currentPage < response.pagination.totalPages
        if response.pagination.totalItems >= 0 {
            totalItemCount = response.pagination.totalItems
        } else if reset {
            totalItemCount = nil
        }
        rebuildSections()
    }

    private func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        await loadNetworks(reset: false)
    }

    private func deleteNetwork(_ network: NetworkSummary) async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "networks/\(network.id)")
            let _: DataResponse<String> = try await client.rest.delete(path)
            withAnimation {
                networks.removeAll { $0.id == network.id }
                rebuildSections()
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
    let network: NetworkSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "network")
                .font(.title3)
                .foregroundStyle(.teal)
                .frame(width: 36, height: 36)


            VStack(alignment: .leading, spacing: 4) {
                Text(network.name)
                    .font(.body)
                    .lineLimit(nil)
                HStack(spacing: 8) {
                    Text(network.driver)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if network.isInternal {
                        Text("• Internal").font(.subheadline).foregroundStyle(.orange)
                    }
                    if network.containerCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "cube.box.fill")
                            Text("\(network.containerCount)")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.teal)
                    }
                }
            }

            Spacer(minLength: 0)
        }

    }
}

struct NetworkDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let network: NetworkSummary
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
            headerSection
            detailsSection

            if let inspect {
                peersSection(inspect)
                servicesSection(inspect)
            }

            if let ipam = inspect?.ipam {
                ipamSection(ipam)
            }

            connectedContainersSection

            if let inspect, !inspect.labels.isEmpty {
                keyValueSection("Labels", systemImage: "tag", pairs: inspect.labels)
            }

            if let inspect, !inspect.options.isEmpty {
                keyValueSection("Options", systemImage: "slider.horizontal.3", pairs: inspect.options)
            }

            if isLoadingInspect && inspect == nil {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading network details…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }

            if let inspectError, inspect == nil {
                Section {
                    Label(inspectError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Retry") { Task { await loadInspect() } }
                }
            }
        }
        .listStyle(.insetGrouped)
        .softTopScrollEdgeEffectCompat()
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
        .deleteConfirmation(
            isPresented: $showDeleteConfirm,
            title: "Delete Network",
            message: "Delete “\(network.name)”? This cannot be undone.",
            icon: "trash",
            confirmTitle: "Delete"
        ) {
            Task { await deleteNetwork() }
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

    private var headerSection: some View {
        Section {
            Label {
                VStack(alignment: .leading) {
                    Text(network.name).font(.headline)
                    Text(network.driver).font(.subheadline).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "network").foregroundStyle(.teal)
            }
        }
    }

    private func infoSection<Content: View>(
        title: String,
        systemImage: String,
        count: Int? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Section {
            content()
        } header: {
            Text(verbatim: count.map { "\(title) (\($0))" } ?? title)
        }
    }

    private var detailsSection: some View {
        infoSection(title: "Details", systemImage: "info.circle") {
            ForEach(networkMetadata) { item in
                LabeledContent(item.label, value: item.value)
            }
            infoRow("ID") { MonospacedValue(value: network.id) }
            if let inspect {
                if inspect.`internal` { infoRow("Internal") { rowText("Yes") } }
                infoRow("Attachable") { rowText(inspect.attachable ? "Yes" : "No") }
                infoRow("IPv4") { rowText(inspect.enableIPv4 ? "Enabled" : "Disabled") }
                infoRow("IPv6") { rowText(inspect.enableIPv6 ? "Enabled" : "Disabled") }
            }
            detailLink("Topology", systemImage: "point.topleft.down.curvedto.point.bottomright.up") {
                NetworkTopologyView(environmentID: environmentID)
            }
        }
    }

    @ViewBuilder
    private func peersSection(_ inspect: NetworkInspect) -> some View {
        if !inspect.peerList.isEmpty {
            infoSection(title: "Peers", systemImage: "globe", count: inspect.peerList.count) {
                ForEach(Array(inspect.peerList.enumerated()), id: \.element.name) { _, peer in
                    infoRow(peer.name) { MonospacedValue(value: peer.address) }
                }
            }
        }
    }

    @ViewBuilder
    private func servicesSection(_ inspect: NetworkInspect) -> some View {
        if !inspect.serviceList.isEmpty {
            infoSection(title: "Services", systemImage: "square.stack.3d.up", count: inspect.serviceList.count) {
                ForEach(Array(inspect.serviceList.enumerated()), id: \.element.name) { _, service in
                    VStack(alignment: .leading, spacing: 5) {
                        MonospacedValue(value: service.name)
                        if let vip = service.vip {
                            LabeledContent("VIP") { MonospacedValue(value: vip) }
                                .font(.subheadline)
                        }
                        if !service.ports.isEmpty {
                            LabeledContent("Ports") {
                                MonospacedValue(value: service.ports.joined(separator: ", "))
                            }
                            .font(.subheadline)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func ipamSection(_ ipam: IPAM) -> some View {
        let hasDriver = ipam.driver.map { !$0.isEmpty } == true
        let hasConfigs = !(ipam.config ?? []).isEmpty
        if hasDriver || hasConfigs {
            infoSection(title: "IPAM", systemImage: "tablecells") {
                // Identity derived from content (offset only disambiguates duplicates)
                // so rows keep stable identity if the config list reorders.
                let ipamConfigs = (ipam.config ?? []).enumerated().map { offset, config in
                    (id: "\(config.subnet ?? "")|\(config.gateway ?? "")|\(config.ipRange ?? "")#\(offset)", config: config)
                }
                ForEach(ipamConfigs, id: \.id) { item in
                    let config = item.config
                    if let subnet = config.subnet, !subnet.isEmpty {
                        infoRow("Subnet") { MonospacedValue(value: subnet) }
                    }
                    if let gw = config.gateway, !gw.isEmpty {
                        infoRow("Gateway") { MonospacedValue(value: gw) }
                    }
                    if let range = config.ipRange, !range.isEmpty {
                        infoRow("IP Range") { MonospacedValue(value: range) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var connectedContainersSection: some View {
        let endpoints = inspect?.containersList ?? []
        let rawContainers = inspect?.containers ?? [:]
        if !endpoints.isEmpty {
            infoSection(title: "Connected Containers", systemImage: "shippingbox.fill", count: endpoints.count) {
                ForEach(endpoints, id: \.id) { endpoint in
                    NetworkContainerRow(endpoint: endpoint)
                    }
            }
        } else if !rawContainers.isEmpty {
            let sortedKeys = Array(rawContainers.keys.sorted())
            infoSection(title: "Connected Containers", systemImage: "shippingbox.fill", count: sortedKeys.count) {
                ForEach(sortedKeys, id: \.self) { key in
                    if case let .object(obj) = rawContainers[key] {
                        NetworkContainerRow(
                            id: key,
                            name: obj["Name"]?.stringValue ?? "",
                            ipv4: obj["IPv4Address"]?.stringValue ?? "",
                            ipv6: obj["IPv6Address"]?.stringValue ?? ""
                        )
                    }
                }
            }
        }
    }

    private func keyValueSection(_ title: String, systemImage: String, pairs: [String: String]) -> some View {
        infoSection(title: title, systemImage: systemImage) {
            ForEach(pairs.keys.sorted(), id: \.self) { key in
                infoRow(key) { rowText(pairs[key] ?? "") }
            }
        }
    }

    private func infoRow(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        LabeledContent(label) { value().textSelection(.enabled) }
    }

    private func rowText(_ value: String) -> some View {
        Text(value)
            .font(.subheadline)
            .multilineTextAlignment(.trailing)
    }


    private func detailLink<Destination: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination()) {
            Label(title, systemImage: systemImage)
        }
    }

    private var networkMetadata: [ResourceMetadataItem] {
        [
            ResourceMetadataItem(label: "Driver", value: network.driver, systemImage: "gearshape"),
            ResourceMetadataItem(label: "Scope", value: network.scope.capitalized, systemImage: "scope"),
            ResourceMetadataItem(label: "Created", value: network.created.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar"),
            ResourceMetadataItem(label: "Status", value: network.inUse ? "In use" : "Unused", systemImage: "circle.fill", tint: network.inUse ? .green : .secondary)
        ]
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
                    FormTextField(
                        title: "Name",
                        placeholder: "frontend",
                        text: $name,
                        autocapitalization: .never,
                        autocorrectionDisabled: true,
                        helper: "Use a short Docker network name with no spaces."
                    )
                    FormPicker(
                        title: "Driver",
                        selection: $driver,
                        helper: "Bridge is the standard single-host Docker network driver."
                    ) {
                        Text("Bridge").tag("bridge")
                        Text("Host").tag("host")
                        Text("Overlay").tag("overlay")
                        Text("Macvlan").tag("macvlan")
                        Text("None").tag("none")
                    }
                    Toggle("Internal", isOn: $isInternal)
                }
                Section {} footer: {
                    Text(isInternal ? "Internal networks block external connectivity for attached containers." : "Bridge is the standard single-host Docker network driver.")
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
            let _: NetworkSummary = try await client.rest.post(path, body: body)
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
