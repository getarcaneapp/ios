import Arcane
import SwiftUI

struct NetworksView: View {
    private static let pageSize = 50

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(EnvironmentsStore.self) private var environmentsStore
    let environmentID: EnvironmentID
    let environmentName: String
    /// All Environments preview: list and act on resources from every enabled environment.
    var allEnvironments = false

    @State private var list = EnvironmentPagedList<NetworkSummary>(pageSize: Self.pageSize)
    @State private var actionErrorMessage: String?
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var showCreateSheet = false
    @State private var createEnvironmentID: EnvironmentID?
    @State private var pendingDestructive: NetworkDestructive?
    @State private var showFilterSheet = false
    @State private var environmentFilter: EnvironmentID?
    @State private var typeFilter = NetworkTypeFilter.all
    @State private var sortOrder = ListSortOrder.ascending
    @State private var systemNetworks: [EnvironmentItem<NetworkSummary>] = []
    @State private var userNetworks: [EnvironmentItem<NetworkSummary>] = []

    /// Both destructive confirmations on this screen route through a single
    /// `.deleteConfirmation` cover (one full-screen cover per view).
    private enum NetworkDestructive {
        case prune
        case delete(EnvironmentItem<NetworkSummary>)
    }

    private var networks: [EnvironmentItem<NetworkSummary>] { list.items }

    /// The environments this list covers, known before the first load finishes.
    private var listEnvironments: [ListEnvironment] {
        allEnvironments ? list.environments : [ListEnvironment(id: environmentID, name: nil)]
    }

    private var activeFilterCount: Int {
        var count = typeFilter != .all ? 1 : 0
        if environmentFilter != nil { count += 1 }
        return count
    }

    private var mutationVersion: Int {
        allEnvironments
            ? mutationStore.version(kind: .networks, in: list.environments)
            : mutationStore.version(kind: .networks, envID: environmentID)
    }

    private static let systemNetworkNames: Set<String> = ["host", "bridge", "none"]

    private static func isSystem(_ network: EnvironmentItem<NetworkSummary>) -> Bool {
        systemNetworkNames.contains(network.name.lowercased())
    }

    /// Filters + sorts once and partitions in a single pass into built-in vs
    /// custom networks. Pure — reads current inputs, returns the two groups.
    private func computePartition() -> (
        system: [EnvironmentItem<NetworkSummary>], user: [EnvironmentItem<NetworkSummary>]
    ) {
        let query = debouncedSearchText
        let filtered = networks.filter { network in
            guard environmentFilter == nil || network.environmentID == environmentFilter else { return false }
            let matchesSearch =
                query.isEmpty || network.name.localizedCaseInsensitiveContains(query)
                || network.driver.localizedCaseInsensitiveContains(query)
            let matchesType =
                typeFilter == .all
                || (typeFilter == .standard && !network.isInternal)
                || (typeFilter == .internalOnly && network.isInternal)
            return matchesSearch && matchesType
        }
        .sorted {
            sortOrder.areInIncreasingOrder($0.name, $1.name)
        }
        var system: [EnvironmentItem<NetworkSummary>] = []
        var user: [EnvironmentItem<NetworkSummary>] = []
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
            showSkeleton: list.isLoading && networks.isEmpty,
            animatesTransition: false
        ) {
            ArcaneLoadingView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } content: {
            if let error = list.errorMessage, networks.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't Load Networks", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await loadNetworks() } }
                }
            } else if networks.isEmpty {
                ContentUnavailableView {
                    Label("No Networks", systemImage: "network")
                } description: {
                    Text(
                        allEnvironments
                            ? "No networks found in any environment." : "No networks found in this environment.")
                } actions: {
                    if allEnvironments {
                        EnvironmentActionButton(
                            title: "Create Network", systemImage: "plus", environments: listEnvironments
                        ) { environmentID in
                            presentCreateSheet(in: environmentID)
                        }
                    } else {
                        Button("Create Network") { presentCreateSheet(in: environmentID) }
                    }
                }
            } else {
                List {
                    EnvironmentLoadFailuresSection(failures: list.failedEnvironments) {
                        Task { await loadNetworks() }
                    }
                    if !systemNetworks.isEmpty {
                        Section {
                            ForEach(systemNetworks) { network in
                                NavigationLink(value: network) {
                                    NetworkRow(network: network.value, environmentName: network.environmentName)
                                        .rowEnvironment(network)
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
                                totalCount: list.totalItems,
                                hasMore: list.hasMore
                            )
                        } footer: {
                            Text("Built-in Docker networks can't be removed.")
                        }
                    }
                    if !userNetworks.isEmpty {
                        Section {
                            ForEach(userNetworks) { network in
                                NavigationLink(value: network) {
                                    NetworkRow(network: network.value, environmentName: network.environmentName)
                                        .rowEnvironment(network)
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
                                    totalCount: list.totalItems,
                                    hasMore: list.hasMore
                                )
                            } else {
                                Text("Custom")
                            }
                        }
                    }
                    PaginatedListFooter(
                        hasMore: list.hasMore,
                        loadMoreError: list.loadMoreError,
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
            AppToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showFilterSheet = true
                } label: {
                    Image(
                        systemName: activeFilterCount > 0
                            ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
                    )
                    .appAccentToolbarSymbol()
                }
                .accessibilityLabel("Filter")
            }
            if #available(iOS 26, *) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            AppToolbarItem(placement: .navigationBarTrailing) {
                if allEnvironments {
                    EnvironmentActionButton(
                        title: "Create Network", systemImage: "plus", environments: listEnvironments
                    ) { environmentID in
                        presentCreateSheet(in: environmentID)
                    }
                    .appAccentToolbarSymbol()
                    .accessibilityLabel("Create network")
                } else {
                    Button {
                        presentCreateSheet(in: environmentID)
                    } label: {
                        Image(systemName: "plus")
                            .appAccentToolbarSymbol()
                    }
                    .accessibilityLabel("Create network")
                }
            }
            AppToolbarItem(placement: .navigationBarTrailing) {
                Button(role: .destructive) {
                    pendingDestructive = .prune
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .disabled(allEnvironments && AllEnvironmentsOperationStore.shared.isRunning)
                .accessibilityLabel("Prune unused networks")
            }
        }
        // Reappearing (back from a detail) refreshes every loaded page in
        // place; the first appear loads page one.
        .task { await loadNetworks(preservingLoadedRange: true) }
        .refreshable { await loadNetworks() }
        .debounce(searchText, for: .milliseconds(200), into: $debouncedSearchText)
        .navigationDestination(for: EnvironmentItem<NetworkSummary>.self) { network in
            NetworkDetailView(network: network.value, environmentID: network.environmentID)
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateNetworkView(environmentID: createEnvironmentID ?? environmentID) {}
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .deleteConfirmation(item: $pendingDestructive) { action in
            switch action {
            case .prune:
                return DeleteConfirmationConfig(
                    title: "Prune Networks",
                    message: allEnvironments
                        ? ResourcePruneAction.networks.allEnvironmentsMessage : "Remove all unused networks.",
                    icon: "trash",
                    actions: [
                        DeleteConfirmationAction(title: "Prune") {
                            Task { await pruneNetworks() }
                        }
                    ]
                )
            case .delete(let network):
                return DeleteConfirmationConfig(
                    title: "Delete Network",
                    message: "Delete “\(network.name)”? This cannot be undone.",
                    icon: "trash",
                    actions: [
                        DeleteConfirmationAction(title: "Delete") {
                            Task { await deleteNetwork(network) }
                        }
                    ]
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
                    Section("Sort") {
                        Picker("Sort", selection: $sortOrder) {
                            ForEach(ListSortOrder.allCases) { order in
                                Label(order.title, systemImage: order.systemImage).tag(order)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    EnvironmentFilterSection(environments: list.environments, selection: $environmentFilter)
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
                    AppToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showFilterSheet = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationContentInteraction(.resizes)
            .presentationDragIndicator(.visible)
        }
        .onChange(of: mutationVersion) { _, _ in
            Task { await loadNetworks(preservingLoadedRange: true) }
        }
        .onChange(of: list.revision) { rebuildSections() }
        .onChange(of: debouncedSearchText) { rebuildSections() }
        .onChange(of: environmentFilter) { rebuildSections() }
        .onChange(of: typeFilter) { rebuildSections() }
        .onChange(of: sortOrder) { rebuildSections() }
    }

    private func networkPreview(_ network: EnvironmentItem<NetworkSummary>) -> some View {
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
            details.insert(
                .init(
                    icon: "shippingbox",
                    label: "Connected Containers",
                    value: "\(network.containerCount)"
                ), at: 0)
        }
        details.append(.init(icon: "number", label: "ID", value: network.value.id, monospaced: true))
        if let environmentName = network.environmentName {
            details.append(.init(icon: "server.rack", label: "Environment", value: environmentName))
        }
        return RowPreviewCard(
            icon: "network",
            iconColor: .teal,
            title: network.name.isEmpty ? network.value.id : network.name,
            badges: badges,
            details: details
        )
    }

    private func presentCreateSheet(in environmentID: EnvironmentID) {
        createEnvironmentID = environmentID
        showCreateSheet = true
    }

    private func loadNetworks(preservingLoadedRange: Bool = false) async {
        guard let client = manager.client else { return }
        let environments = await environmentsStore.listEnvironments(
            environmentID, allEnvironments: allEnvironments, manager: manager)
        await list.reload(
            environments, preservingLoadedRange: preservingLoadedRange, fetch: networksPage(client: client))
        rebuildSections()
    }

    private func loadMore() async {
        guard let client = manager.client else { return }
        await list.loadMore(fetch: networksPage(client: client))
        rebuildSections()
    }

    private func networksPage(client: ArcaneClient) -> EnvironmentPagedList<NetworkSummary>.Fetch {
        { environmentID, start, limit in
            // `PaginatedResponse<NetworkSummary>` is Decodable-only and can't
            // pass through the cache (Codable). Fetch directly.
            let response = try await client.networks.list(
                envID: environmentID,
                query: .init(start: start, limit: limit)
            )
            return ResourcePage(items: response.data, pagination: response.pagination)
        }
    }

    private func deleteNetwork(_ network: EnvironmentItem<NetworkSummary>) async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(network.environmentID, "networks/\(network.value.id)")
            let _: DataResponse<String> = try await client.rest.delete(path)
            withAnimation {
                list.update { $0.removeAll { $0.id == network.id } }
                rebuildSections()
            }
            await invalidateNetworkCaches(network.environmentID)
            mutationStore.markChanged(kind: .networks, envID: network.environmentID)
            showToast(.success("Network deleted"))
        } catch {
            actionErrorMessage = friendlyErrorMessage(error)
        }
    }

    private func pruneNetworks() async {
        if allEnvironments {
            await AllEnvironmentsOperationStore.shared.performPrune(
                .networks, environments: environmentsStore.enabledEnvironments, manager: manager)
            return
        }
        guard let client = manager.client else { return }
        do {
            try await ResourcePruneAction.networks.perform(client: client, environmentID: environmentID)
            await invalidateNetworkCaches(environmentID)
            mutationStore.markChanged(kind: .networks, envID: environmentID)
            showToast(.success("Networks pruned"))
        } catch {
            actionErrorMessage = friendlyErrorMessage(error)
        }
    }

    private func invalidateNetworkCaches(_ environmentID: EnvironmentID) async {
        guard let cached = manager.cached, let client = manager.client else { return }
        await cached.invalidate(
            envID: environmentID,
            paths: [
                client.rest.environmentPath(environmentID, "networks"),
                client.rest.environmentPath(environmentID, "networks/*"),
            ])
    }
}

struct NetworkRow: View {
    let network: NetworkSummary

    var environmentName: String? = nil

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
                EnvironmentLabel(name: environmentName)
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
    @State private var showConnect = false
    @State private var pendingDisconnect: NetworkDisconnectTarget?

    private var isBuiltIn: Bool {
        ["host", "bridge", "none"].contains(network.name.lowercased())
    }

    /// Docker doesn't allow attaching containers to the host or none networks.
    private var canConnect: Bool {
        !["host", "none"].contains(network.name.lowercased())
            && manager.permissions.has("networks:connect", in: environmentID)
    }

    private var canDisconnect: Bool {
        manager.permissions.has("networks:disconnect", in: environmentID)
    }

    private var connectedContainerIDs: Set<String> {
        var ids = Set(inspect?.containersList.map(\.id) ?? [])
        if let keys = inspect?.containers.keys { ids.formUnion(keys) }
        return ids
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
                keyValueSection("Labels", pairs: inspect.labels)
            }

            if let inspect, !inspect.options.isEmpty {
                keyValueSection("Options", pairs: inspect.options)
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
            if canConnect {
                AppToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showConnect = true
                    } label: {
                        Image(systemName: "link.badge.plus")
                            .appAccentToolbarSymbol()
                    }
                    .accessibilityLabel("Connect Container")
                }
            }
            if !isBuiltIn {
                AppToolbarItem(placement: .navigationBarTrailing) {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .sheet(isPresented: $showConnect) {
            ConnectNetworkContainerSheet(
                networkID: network.id,
                networkName: network.name,
                environmentID: environmentID,
                excludedContainerIDs: connectedContainerIDs
            ) {
                await networkMembershipChanged()
            }
        }
        .deleteConfirmation(item: $pendingDisconnect) { target in
            DeleteConfirmationConfig(
                title: "Disconnect Container",
                message: "Disconnect “\(target.name)” from \(network.name)?",
                icon: "link",
                actions: [
                    DeleteConfirmationAction(title: "Disconnect") {
                        Task { await disconnect(target) }
                    }
                ]
            )
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
        infoSection(title: "Details") {
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
            infoSection(title: "Peers", count: inspect.peerList.count) {
                ForEach(Array(inspect.peerList.enumerated()), id: \.element.name) { _, peer in
                    infoRow(peer.name) { MonospacedValue(value: peer.address) }
                }
            }
        }
    }

    @ViewBuilder
    private func servicesSection(_ inspect: NetworkInspect) -> some View {
        if !inspect.serviceList.isEmpty {
            infoSection(title: "Services", count: inspect.serviceList.count) {
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
            infoSection(title: "IPAM") {
                // Identity derived from content (offset only disambiguates duplicates)
                // so rows keep stable identity if the config list reorders.
                let ipamConfigs = (ipam.config ?? []).enumerated().map { offset, config in
                    (
                        id: "\(config.subnet ?? "")|\(config.gateway ?? "")|\(config.ipRange ?? "")#\(offset)",
                        config: config
                    )
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
            infoSection(title: "Connected Containers", count: endpoints.count) {
                ForEach(endpoints, id: \.id) { endpoint in
                    let row = NetworkContainerRow(endpoint: endpoint)
                    disconnectable(row, target: NetworkDisconnectTarget(id: endpoint.id, name: row.displayName))
                }
            }
        } else if !rawContainers.isEmpty {
            let sortedKeys = Array(rawContainers.keys.sorted())
            infoSection(title: "Connected Containers", count: sortedKeys.count) {
                ForEach(sortedKeys, id: \.self) { key in
                    if case .object(let obj) = rawContainers[key] {
                        let row = NetworkContainerRow(
                            id: key,
                            name: obj["Name"]?.stringValue ?? "",
                            ipv4: obj["IPv4Address"]?.stringValue ?? "",
                            ipv6: obj["IPv6Address"]?.stringValue ?? ""
                        )
                        disconnectable(row, target: NetworkDisconnectTarget(id: key, name: row.displayName))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func disconnectable(_ row: NetworkContainerRow, target: NetworkDisconnectTarget) -> some View {
        if canDisconnect {
            row
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        pendingDisconnect = target
                    } label: {
                        Label("Disconnect", systemImage: "link")
                    }
                    .tint(.red)
                }
                .contextMenu {
                    Button(role: .destructive) {
                        pendingDisconnect = target
                    } label: {
                        DestructiveLabel(text: "Disconnect", systemImage: "link")
                    }
                    .tint(.red)
                }
        } else {
            row
        }
    }

    private func disconnect(_ target: NetworkDisconnectTarget) async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "networks/\(network.id)/disconnect")
            try await client.rest.postVoid(path, body: NetworkDisconnectRequest(containerId: target.id))
            await networkMembershipChanged()
            showToast(.success("Container disconnected"))
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    /// Connections change both the network and the container's network settings.
    private func networkMembershipChanged() async {
        if let cached = manager.cached, let client = manager.client {
            await cached.invalidate(
                envID: environmentID,
                paths: [
                    client.rest.environmentPath(environmentID, "networks"),
                    client.rest.environmentPath(environmentID, "networks/*"),
                    client.rest.environmentPath(environmentID, "containers"),
                    client.rest.environmentPath(environmentID, "containers/*"),
                ])
        }
        mutationStore.markChanged(kind: .networks, envID: environmentID)
        mutationStore.markChanged(kind: .containers, envID: environmentID)
        await loadInspect()
    }

    private func keyValueSection(_ title: String, pairs: [String: String]) -> some View {
        infoSection(title: title) {
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
            ResourceMetadataItem(
                label: "Created", value: network.created.formatted(date: .abbreviated, time: .shortened),
                systemImage: "calendar"),
            ResourceMetadataItem(
                label: "Status", value: network.inUse ? "In use" : "Unused", systemImage: "circle.fill",
                tint: network.inUse ? .green : .secondary),
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
                await cached.invalidate(
                    envID: environmentID,
                    paths: [
                        client.rest.environmentPath(environmentID, "networks"),
                        client.rest.environmentPath(environmentID, "networks/*"),
                    ])
            }
            mutationStore.markChanged(kind: .networks, envID: environmentID)
            showToast(.success("Network deleted"))
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
    @State private var subnet = ""
    @State private var gateway = ""
    @State private var ipRange = ""
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
                Section("IPAM (Optional)") {
                    FormTextField(
                        title: "Subnet",
                        placeholder: "10.0.0.0/24",
                        text: $subnet,
                        autocapitalization: .never,
                        autocorrectionDisabled: true
                    )
                    FormTextField(
                        title: "Gateway",
                        placeholder: "10.0.0.1",
                        text: $gateway,
                        autocapitalization: .never,
                        autocorrectionDisabled: true
                    )
                    FormTextField(
                        title: "IP Range",
                        placeholder: "10.0.0.128/25",
                        text: $ipRange,
                        autocapitalization: .never,
                        autocorrectionDisabled: true,
                        helper: "Optional sub-range carved from the subnet."
                    )
                }
                Section {
                } footer: {
                    Text(
                        isInternal
                            ? "Internal networks block external connectivity for attached containers."
                            : "Bridge is the standard single-host Docker network driver.")
                }
                if let error = errorMessage {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Create Network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                AppToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await createNetwork() } }
                        .disabled(name.isEmpty || isLoading)
                }
            }
        }
    }

    private func createNetwork() async {
        guard let client = manager.client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            var body: [String: JSONValue] = [
                "name": JSONValue(name),
                "driver": JSONValue(driver),
                "internal": JSONValue(isInternal),
            ]
            let trimmedSubnet = subnet.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedGateway = gateway.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedRange = ipRange.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSubnet.isEmpty || !trimmedGateway.isEmpty || !trimmedRange.isEmpty {
                var config: [String: JSONValue] = [:]
                if !trimmedSubnet.isEmpty { config["subnet"] = JSONValue(trimmedSubnet) }
                if !trimmedGateway.isEmpty { config["gateway"] = JSONValue(trimmedGateway) }
                if !trimmedRange.isEmpty { config["ipRange"] = JSONValue(trimmedRange) }
                body["ipam"] = JSONValue(["config": JSONValue([JSONValue(config)])])
            }
            let path = client.rest.environmentPath(environmentID, "networks")
            let _: NetworkSummary = try await client.rest.post(path, body: body)
            if let cached = manager.cached {
                await cached.invalidate(
                    envID: environmentID,
                    paths: [
                        client.rest.environmentPath(environmentID, "networks"),
                        client.rest.environmentPath(environmentID, "networks/*"),
                    ])
            }
            mutationStore.markChanged(kind: .networks, envID: environmentID)
            showToast(.success("Network created"))
            await onSuccess()
            dismiss()
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

    var displayName: String {
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

private struct NetworkDisconnectTarget: Identifiable {
    let id: String
    let name: String
}

/// Attaches an existing container to a network, optionally with aliases and a
/// static IPv4 address.
private struct ConnectNetworkContainerSheet: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let networkID: String
    let networkName: String
    let environmentID: EnvironmentID
    let excludedContainerIDs: Set<String>
    let onConnected: () async -> Void

    @State private var containers: [ContainerSummary] = []
    @State private var isLoading = false
    @State private var selectedID: String?
    @State private var aliases = ""
    @State private var ipv4 = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var candidates: [ContainerSummary] {
        containers
            .filter { !excludedContainerIDs.contains($0.id) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Container") {
                    if isLoading && containers.isEmpty {
                        ArcaneLoadingView().frame(maxWidth: .infinity)
                    } else if candidates.isEmpty {
                        Text("No other containers available.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(candidates) { container in
                            Button {
                                selectedID = container.id
                            } label: {
                                HStack(spacing: 12) {
                                    StatusIcon(status: container.status, isLive: container.isRunning)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(container.displayName)
                                            .foregroundStyle(.primary)
                                        Text(container.image)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    if selectedID == container.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                }
                Section {
                    FormTextField(
                        title: "Aliases",
                        placeholder: "web, api",
                        text: $aliases,
                        autocapitalization: .never,
                        autocorrectionDisabled: true,
                        helper: "Comma-separated DNS names on this network."
                    )
                    FormTextField(
                        title: "IPv4 Address",
                        placeholder: "Automatic",
                        text: $ipv4,
                        keyboardType: .numbersAndPunctuation,
                        autocapitalization: .never,
                        autocorrectionDisabled: true
                    )
                } header: {
                    Text("Options")
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle("Connect to \(networkName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
                AppToolbarItem(placement: .topBarTrailing) {
                    Button("Connect") {
                        Task { await connect() }
                    }
                    .disabled(selectedID == nil || isSubmitting)
                }
            }
            .interactiveDismissDisabled(isSubmitting)
            .task { await loadContainers() }
        }
    }

    private func loadContainers() async {
        guard let client = manager.client, let cached = manager.cached else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            containers = try await cached.getAllPages(
                path: client.rest.environmentPath(environmentID, "containers"),
                elementType: ContainerSummary.self,
                envID: environmentID,
                fetchPage: { start, limit in
                    let response = try await client.containers.list(
                        envID: environmentID,
                        query: .init(start: start, limit: limit)
                    )
                    return ResourcePage(items: response.data, pagination: response.pagination)
                }
            )
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func connect() async {
        guard let client = manager.client, let selectedID else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        let aliasList = aliases.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let address = ipv4.trimmingCharacters(in: .whitespaces)
        let body = NetworkConnectRequest(
            containerId: selectedID,
            aliases: aliasList.isEmpty ? nil : aliasList,
            ipv4Address: address.isEmpty ? nil : address
        )
        do {
            let path = client.rest.environmentPath(environmentID, "networks/\(networkID)/connect")
            try await client.rest.postVoid(path, body: body)
            showToast(.success("Container connected"))
            await onConnected()
            dismiss()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
