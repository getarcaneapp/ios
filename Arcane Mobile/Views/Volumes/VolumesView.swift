import Arcane
import SwiftUI

struct VolumesView: View {
    private static let pageSize = 50

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(PinnedItemsStore.self) private var pinnedStore
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(EnvironmentsStore.self) private var environmentsStore
    let environmentID: EnvironmentID
    let environmentName: String
    /// All Environments preview: list and act on resources from every enabled environment.
    var allEnvironments = false

    @State private var list = EnvironmentPagedList<Volume>(pageSize: Self.pageSize)
    /// Volume sizes by environment, then by volume name — names repeat across environments.
    @State private var sizes: [EnvironmentID: [String: Int64]] = [:]
    @State private var actionErrorMessage: String?
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var showCreateSheet = false
    @State private var createEnvironmentID: EnvironmentID?
    @State private var pendingDestructive: VolumeDestructive?
    @State private var showFilterSheet = false
    @State private var environmentFilter: EnvironmentID?
    @State private var scopeFilter = VolumeScopeFilter.all
    @State private var sortOrder = ListSortOrder.ascending
    @State private var loadGeneration = 0
    @State private var sections: [StableListSection<String, EnvironmentItem<Volume>>] = []

    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var isBulkRunning = false
    @State private var bulkRunningActionID: String?

    /// Prune and per-volume delete share one `.deleteConfirmation` cover
    /// (one full-screen cover per view).
    private enum VolumeDestructive {
        case prune
        case delete(EnvironmentItem<Volume>)
        case bulkDelete([String])
    }

    private var volumes: [EnvironmentItem<Volume>] { list.items }

    /// The environments this list covers, known before the first load finishes.
    private var listEnvironments: [ListEnvironment] {
        allEnvironments ? list.environments : [ListEnvironment(id: environmentID, name: nil)]
    }

    /// Environments offered by Create Volume.
    private var createEnvironments: [ListEnvironment] {
        guard allEnvironments else { return listEnvironments }
        return listEnvironments.filter { manager.permissions.has(Permission.Volumes.create, in: $0.id) }
    }

    private var activeFilterCount: Int {
        var count = scopeFilter != .all ? 1 : 0
        if environmentFilter != nil { count += 1 }
        return count
    }

    private var pinnedIDs: Set<String> {
        pinnedStore.pinnedIDs(kind: .volume, in: volumes)
    }

    private func size(of volume: EnvironmentItem<Volume>) -> Int64? {
        sizes[volume.environmentID]?[volume.name]
    }

    /// Filters + sorts once and partitions in a single pass. Pure — reads the
    /// current inputs and returns the grouped sections without touching state.
    private func computeSections() -> [StableListSection<String, EnvironmentItem<Volume>>] {
        let query = debouncedSearchText
        let filtered = volumes.filter { volume in
            guard environmentFilter == nil || volume.environmentID == environmentFilter else { return false }
            let matchesSearch =
                query.isEmpty || volume.name.localizedCaseInsensitiveContains(query)
                || volume.driver.localizedCaseInsensitiveContains(query)
            let matchesScope =
                scopeFilter == .all
                || (scopeFilter == .local && volume.scope.lowercased() == "local")
                || (scopeFilter == .global && volume.scope.lowercased() != "local")
            return matchesSearch && matchesScope
        }
        .sorted {
            sortOrder.areInIncreasingOrder($0.name, $1.name)
        }
        let pinned: Set<String> = pinnedIDs
        var pinnedItems: [EnvironmentItem<Volume>] = []
        var used: [EnvironmentItem<Volume>] = []
        var unused: [EnvironmentItem<Volume>] = []
        for volume in filtered {
            if pinned.contains(volume.id) {
                pinnedItems.append(volume)
            } else if volume.inUse == true {
                used.append(volume)
            } else {
                unused.append(volume)
            }
        }
        return [
            .init(id: "pinned", title: "Pinned", items: pinnedItems),
            .init(id: "used", title: "Used", items: used),
            .init(id: "unused", title: "Unused", items: unused),
        ]
    }

    /// Refresh the cached `sections`. Called only when an input that affects
    /// grouping actually changes (search settle, sort, filter, pins, or the
    /// source list) — never on every body evaluation. Volume sizes are read
    /// per-row and don't affect grouping, so they don't trigger a rebuild.
    private func rebuildSections() {
        sections = computeSections()
        pruneSelection(validIDs: Set(volumes.map(\.id)))
    }

    private var mutationVersion: Int {
        allEnvironments
            ? mutationStore.version(kind: .volumes, in: list.environments)
            : mutationStore.version(kind: .volumes, envID: environmentID)
    }

    /// Per-section item counts — drives the List's implicit reflow animation so a
    /// programmatic insert/remove animates too.

    private var selectedVolumes: [EnvironmentItem<Volume>] {
        volumes.filter { selection.contains($0.id) }
    }

    private var bulkPrimaryItem: ActionButtonItem? {
        guard !selection.isEmpty else { return nil }
        return ActionButtonItem(
            id: "bulk-delete",
            title: "Delete",
            systemImage: "trash",
            tint: .red
        ) {
            pendingDestructive = .bulkDelete(selectedVolumes.map(\.id))
        }
    }

    var body: some View {
        LoadingCrossfade(
            showSkeleton: list.isLoading && volumes.isEmpty,
            animatesTransition: false
        ) {
            ArcaneLoadingView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } content: {
            if let error = list.errorMessage, volumes.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't Load Volumes", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await loadVolumes() } }
                }
            } else if volumes.isEmpty {
                ContentUnavailableView {
                    Label("No Volumes", systemImage: "externaldrive")
                } description: {
                    Text(
                        allEnvironments
                            ? "No volumes found in any environment." : "No volumes found in this environment.")
                } actions: {
                    if allEnvironments {
                        EnvironmentActionButton(
                            title: "Create Volume", systemImage: "plus", environments: createEnvironments
                        ) { environmentID in
                            presentCreate(in: environmentID)
                        }
                    } else {
                        Button("Create Volume") { presentCreate(in: environmentID) }
                    }
                }
            } else {
                List(selection: BulkListSelection.binding($selection, isSelecting: isSelecting)) {
                    EnvironmentLoadFailuresSection(failures: list.failedEnvironments) {
                        Task { await loadVolumes() }
                    }
                    StableSectionedList(
                        sections,
                        preferredHeaderAccessorySectionID: "used",
                        headerAccessory: { _ in
                            ResourceCountLabel(
                                loadedCount: volumes.count,
                                totalCount: list.totalItems,
                                hasMore: list.hasMore
                            )
                        }
                    ) { volume in
                        volumeLink(volume)
                    }

                    PaginatedListFooter(
                        hasMore: list.hasMore,
                        loadMoreError: list.loadMoreError,
                        onRetry: { Task { await loadMore() } },
                        onLoadMore: { Task { await loadMore() } }
                    )
                }
                .listStyle(.insetGrouped)
                .environment(\.editMode, .constant(isSelecting ? EditMode.active : EditMode.inactive))

            }
        }
        .navigationTitle("Volumes")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search volumes")
        .toolbar {
            if !isSelecting {
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
                AppToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            enterSelectionMode()
                        } label: {
                            Label("Select", systemImage: "checklist")
                        }
                        Divider()
                        Button(role: .destructive) {
                            pendingDestructive = .prune
                        } label: {
                            DestructiveLabel(text: "Prune Unused Volumes")
                        }
                        .tint(.red)
                        .disabled(allEnvironments && AllEnvironmentsOperationStore.shared.isRunning)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .appAccentToolbarSymbol()
                    }
                    .accessibilityLabel("More options")
                }
            } else {
                AppToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        exitSelectionMode()
                    }
                }
            }

            if !isSelecting {
                if #available(iOS 26, *) {
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
                AppToolbarItem(placement: .navigationBarTrailing) {
                    if allEnvironments {
                        EnvironmentActionButton(
                            title: "Create Volume", systemImage: "plus", environments: createEnvironments
                        ) { environmentID in
                            presentCreate(in: environmentID)
                        }
                        .labelStyle(.iconOnly)
                        .appAccentToolbarSymbol()
                        .accessibilityLabel("Create volume")
                    } else {
                        Button {
                            presentCreate(in: environmentID)
                        } label: {
                            Image(systemName: "plus")
                                .appAccentToolbarSymbol()
                        }
                        .accessibilityLabel("Create volume")
                    }
                }
            }
        }
        .task { await loadVolumes() }
        .refreshable { await loadVolumes(refresh: true) }
        .debounce(searchText, for: .milliseconds(200), into: $debouncedSearchText)
        .navigationDestination(for: EnvironmentItem<Volume>.self) { volume in
            VolumeDetailView(volume: volume.value, environmentID: volume.environmentID)
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateVolumeView(environmentID: createEnvironmentID ?? environmentID) {}
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .deleteConfirmation(item: $pendingDestructive) { action in
            switch action {
            case .prune:
                return DeleteConfirmationConfig(
                    title: "Prune Unused Volumes",
                    message: allEnvironments
                        ? ResourcePruneAction.volumes.allEnvironmentsMessage
                        : "All unused volumes will be permanently deleted.",
                    icon: "trash",
                    actions: [
                        DeleteConfirmationAction(title: "Prune") {
                            Task { await pruneVolumes() }
                        }
                    ]
                )
            case .delete(let volume):
                return DeleteConfirmationConfig(
                    title: "Delete Volume",
                    message: "Delete “\(volume.name)”? This cannot be undone.",
                    icon: "trash",
                    actions: [
                        DeleteConfirmationAction(title: "Delete") {
                            Task { await deleteVolume(volume) }
                        }
                    ]
                )
            case .bulkDelete(let ids):
                return DeleteConfirmationConfig(
                    title: "Delete Volumes",
                    message: "Delete \(ids.count) selected volume"
                        + "\(ids.count == 1 ? "" : "s")? This cannot be undone.",
                    icon: "trash",
                    actions: [
                        DeleteConfirmationAction(title: "Delete") {
                            Task { await bulkDeleteVolumes(ids: ids) }
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
                    Section("Scope") {
                        Picker("Scope", selection: $scopeFilter) {
                            ForEach(VolumeScopeFilter.allCases, id: \.self) { filter in
                                Text(filter.rawValue).tag(filter)
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
            Task { await loadVolumes(refresh: true) }
        }
        .onChange(of: debouncedSearchText) { rebuildSections() }
        .onChange(of: environmentFilter) { rebuildSections() }
        .onChange(of: scopeFilter) { rebuildSections() }
        .onChange(of: sortOrder) { rebuildSections() }
        .onChange(of: pinnedIDs) { rebuildSections() }
        .resourceActionsToolbar(
            primary: bulkPrimaryItem,
            runningItemID: bulkRunningActionID,
            isDisabled: isBulkRunning,
            resourceName: "\(selection.count) selected",
            active: isSelecting && !selection.isEmpty
        )
    }

    private func volumeLink(_ volume: EnvironmentItem<Volume>) -> some View {
        let isPinned = pinnedIDs.contains(volume.id)
        return NavigationLink(value: volume) {
            VolumeRow(
                volume: volume.value, size: size(of: volume), isPinned: isPinned,
                environmentName: volume.environmentName
            )
            .rowEnvironment(volume)
        }
        .contextMenu {
            if !isSelecting {
                Button {
                    togglePin(volume)
                } label: {
                    Label(
                        isPinned ? "Unpin" : "Pin",
                        systemImage: isPinned ? "pin.slash.fill" : "pin.fill")
                }
                Button(role: .destructive) {
                    pendingDestructive = .delete(volume)
                } label: {
                    DestructiveLabel(text: "Delete")
                }
                .tint(.red)
            }
        } preview: {
            if !isSelecting {
                volumePreview(volume)
                    .environment(manager)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if !isSelecting {
                Button {
                    togglePinAfterSwipe(volume)
                } label: {
                    Label(
                        isPinned ? "Unpin" : "Pin",
                        systemImage: isPinned ? "pin.slash.fill" : "pin.fill")
                }
                .tint(.yellow)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isSelecting {
                Button {
                    pendingDestructive = .delete(volume)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
        }
    }

    private func presentCreate(in environmentID: EnvironmentID) {
        createEnvironmentID = environmentID
        showCreateSheet = true
    }

    private func enterSelectionMode() {
        HapticsManager.light()
        isSelecting = true
    }

    private func exitSelectionMode() {
        isSelecting = false
        selection.removeAll()
    }

    private func pruneSelection(validIDs: Set<String>) {
        selection.formIntersection(validIDs)
    }

    private func togglePinAfterSwipe(_ volume: EnvironmentItem<Volume>) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            togglePin(volume)
        }
    }

    private func togglePin(_ volume: EnvironmentItem<Volume>) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pinnedStore.togglePin(volume, kind: .volume)
        }
    }

    private func volumePreview(_ volume: EnvironmentItem<Volume>) -> some View {
        var badges: [RowPreviewCard.PreviewBadge] = []
        badges.append(
            .init(
                text: volume.inUse ? "In Use" : "Unused",
                color: volume.inUse ? .green : .secondary))
        var details: [RowPreviewCard.PreviewDetail] = [
            .init(icon: "gearshape", label: "Driver", value: volume.driver),
            .init(icon: "globe", label: "Scope", value: volume.scope.capitalized),
        ]
        if let size = size(of: volume), size > 0 {
            details.insert(.init(icon: "internaldrive", label: "Size", value: size.byteString), at: 0)
        }
        if !volume.mountpoint.isEmpty {
            details.append(.init(icon: "folder", label: "Mount Point", value: volume.mountpoint))
        }
        if let environmentName = volume.environmentName {
            details.append(.init(icon: "server.rack", label: "Environment", value: environmentName))
        }
        return RowPreviewCard(
            icon: "externaldrive.fill",
            iconColor: .orange,
            title: volume.name,
            badges: badges,
            details: details
        )
    }

    private func loadVolumes(refresh: Bool = false) async {
        guard let client = manager.client else { return }
        loadGeneration += 1
        let generation = loadGeneration
        let environments = await environmentsStore.listEnvironments(
            environmentID, allEnvironments: allEnvironments, manager: manager)
        await list.reload(environments, fetch: volumesPage(client: client))
        rebuildSections()
        guard loadGeneration == generation, !Task.isCancelled else { return }
        await loadSizes(for: environments.map(\.id), refresh: refresh)
    }

    private func loadMore() async {
        guard let client = manager.client else { return }
        await list.loadMore(fetch: volumesPage(client: client))
        rebuildSections()
        let missing = list.environments.map(\.id).filter { sizes[$0] == nil }
        if !missing.isEmpty { await loadSizes(for: missing) }
    }

    private func volumesPage(client: ArcaneClient) -> EnvironmentPagedList<Volume>.Fetch {
        // `PaginatedResponse<Volume>` is Decodable-only, so we can't route
        // it through the cache layer (which requires Codable). Fetch
        // directly through the SDK.
        return { environmentID, start, limit in
            let response = try await client.volumes.list(
                envID: environmentID,
                query: .init(start: start, limit: limit)
            )
            return ResourcePage(items: response.data, pagination: response.pagination)
        }
    }

    /// Sizes come per environment (`volumes/sizes` isn't paginated), so each
    /// environment in the list loads its own map.
    private func loadSizes(for environmentIDs: [EnvironmentID], refresh: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            for environmentID in environmentIDs {
                group.addTask { await loadSizes(for: environmentID, refresh: refresh) }
            }
        }
    }

    private func loadSizes(for environmentID: EnvironmentID, refresh: Bool) async {
        guard let client = manager.client, let cached = manager.cached else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "volumes/sizes")
            if let entries: [VolumeSizeInfo] = try await cached.get(
                path, as: [VolumeSizeInfo].self, policy: .volumes,
                envID: environmentID, refresh: refresh,
                onFresh: { fresh in
                    sizes[environmentID] = Dictionary(
                        fresh.map { ($0.name, $0.size) }, uniquingKeysWith: { _, new in new })
                }
            ) {
                sizes[environmentID] = Dictionary(
                    entries.map { ($0.name, $0.size) }, uniquingKeysWith: { _, new in new })
            }
        } catch {
            // Slow / unsupported on some hosts — leave sizes blank silently.
        }
    }

    private func deleteVolume(_ volume: EnvironmentItem<Volume>) async {
        guard let client = manager.client else { return }
        do {
            try await client.volumes.remove(envID: volume.environmentID, name: volume.name)
            withAnimation {
                list.update { $0.removeAll { $0.id == volume.id } }
                rebuildSections()
            }
            await invalidateVolumeCaches(volume.environmentID)
            mutationStore.markChanged(kind: .volumes, envID: volume.environmentID)
            showToast(.success("Volume deleted"))
        } catch {
            actionErrorMessage = friendlyErrorMessage(error)
        }
    }

    private func pruneVolumes() async {
        if allEnvironments {
            await AllEnvironmentsOperationStore.shared.performPrune(
                .volumes, environments: environmentsStore.enabledEnvironments, manager: manager)
            return
        }
        guard let client = manager.client else { return }
        do {
            try await ResourcePruneAction.volumes.perform(client: client, environmentID: environmentID)
            await invalidateVolumeCaches(environmentID)
            mutationStore.markChanged(kind: .volumes, envID: environmentID)
            showToast(.success("Volumes pruned"))
        } catch {
            actionErrorMessage = friendlyErrorMessage(error)
        }
    }

    private func bulkDeleteVolumes(ids: [String]) async {
        guard let client = manager.client else { return }
        isBulkRunning = true
        bulkRunningActionID = "bulk-delete"
        defer {
            isBulkRunning = false
            bulkRunningActionID = nil
        }
        let targets = volumes.filter { ids.contains($0.id) }
        let byID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
        let result = await BulkActionRunner.run(ids: targets.map(\.id)) { id in
            guard let volume = byID[id] else { return }
            try await client.volumes.remove(envID: volume.environmentID, name: volume.name)
        }
        let failedIDs = Set(result.failed.map(\.id))
        let removed = targets.filter { !failedIDs.contains($0.id) }
        let removedIDs = Set(removed.map(\.id))
        list.update { $0.removeAll { removedIDs.contains($0.id) } }
        for volume in removed {
            sizes[volume.environmentID]?.removeValue(forKey: volume.name)
        }
        rebuildSections()
        for environment in Set(targets.map(\.environmentID)) {
            await invalidateVolumeCaches(environment)
            mutationStore.markChanged(kind: .volumes, envID: environment)
        }
        exitSelectionMode()
        if result.failed.isEmpty {
            showToast(.success("Deleted \(result.succeeded) volume\(result.succeeded == 1 ? "" : "s")"))
            ReviewPrompter.shared.recordSuccess()
        } else {
            showToast(.error("\(result.failed.count) of \(targets.count) failed"))
        }
    }

    private func invalidateVolumeCaches(_ environmentID: EnvironmentID) async {
        guard let cached = manager.cached, let client = manager.client else { return }
        await cached.invalidate(
            envID: environmentID,
            paths: [
                client.rest.environmentPath(environmentID, "volumes"),
                client.rest.environmentPath(environmentID, "volumes/sizes"),
                client.rest.environmentPath(environmentID, "volumes/*"),
            ])
    }
}

struct UsageBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(color)

    }
}

struct VolumeRow: View {
    let volume: Volume
    var size: Int64?
    var isPinned: Bool = false

    private var subtitleParts: [String] {
        var parts: [String] = []
        if let size, size > 0 {
            parts.append(size.byteString)
        }
        if volume.driver.lowercased() != "local" {
            parts.append(volume.driver)
        }
        return parts
    }

    var environmentName: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(volume.name)
                        .font(.body)
                        .lineLimit(nil)
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .accessibilityHidden(true)
                    }
                }
                HStack(spacing: 6) {
                    if volume.inUse == true {
                        UsageBadge(text: "In use", color: .green)
                    } else if volume.inUse == false {
                        UsageBadge(text: "Unused", color: .secondary)
                    }
                    if !subtitleParts.isEmpty {
                        Text(subtitleParts.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(nil)
                    }
                }
                EnvironmentLabel(name: environmentName)
            }
        }

        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var parts: [String] = [volume.name]
        if isPinned { parts.append("pinned") }
        if volume.inUse == true {
            parts.append("in use")
        } else if volume.inUse == false {
            parts.append("unused")
        }
        if !subtitleParts.isEmpty { parts.append(subtitleParts.joined(separator: ", ")) }
        if let environmentName { parts.append(environmentName) }
        return parts.joined(separator: ", ")
    }
}

struct VolumeDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let volume: Volume
    let environmentID: EnvironmentID

    @State private var sizeBytes: Int64?
    @State private var loadingSize = false
    @State private var errorMessage: String?
    @State private var route: VolumeRoute?
    @State private var resolvedContainersByID: [String: ContainerSummary] = [:]

    private enum VolumeRoute: Hashable { case browse, backups }

    var body: some View {
        List {
            headerSection
            detailsSection

            if !volume.containers.isEmpty {
                consumersSection
            }

            labelsSection
            optionsSection
        }
        .listStyle(.insetGrouped)
        .softTopScrollEdgeEffectCompat()
        .resourceActionsToolbar(
            primary: ActionButtonItem(
                id: "browse",
                title: "Browse Files",
                systemImage: "folder",
                tint: .accentColor
            ) {
                route = .browse
            },
            secondary: [
                ActionButtonItem(
                    id: "backups",
                    title: "Backups",
                    systemImage: "clock.arrow.circlepath",
                    tint: .accentColor
                ) {
                    route = .backups
                }
            ],
            overflow: [
                ActionButtonItem(
                    id: "delete",
                    title: "Delete",
                    systemImage: "trash",
                    tint: .red,
                    role: .destructive
                ) {
                    Task { await deleteVolume() }
                }
            ],
            resourceName: volume.name
        )
        .navigationTitle(volume.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $route) { route in
            switch route {
            case .browse:
                VolumeBrowserView(environmentID: environmentID, volumeName: volume.name)
            case .backups:
                VolumeBackupsView(environmentID: environmentID, volumeName: volume.name)
            }
        }
        .task {
            async let size: Void = loadSize()
            async let consumers: Void = loadConsumers()
            _ = await (size, consumers)
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
                    Text(volume.name).font(.headline)
                    Text(volume.driver).font(.subheadline).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "externaldrive.fill").foregroundStyle(.orange)
            }
        }
    }

    private var detailsSection: some View {
        Section("Details") {
            ForEach(volumeMetadata) { item in
                LabeledContent(item.label, value: item.value)
            }
            if !volume.mountpoint.isEmpty {
                LabeledContent("Mount Point") {
                    MonospacedValue(value: volume.mountpoint).textSelection(.enabled)
                }
            }
            NavigationLink {
                VolumeBrowserView(environmentID: environmentID, volumeName: volume.name)
            } label: {
                Label("Browse Files", systemImage: "folder")
            }
            NavigationLink {
                VolumeBackupsView(environmentID: environmentID, volumeName: volume.name)
            } label: {
                Label("Backups", systemImage: "clock.arrow.circlepath")
            }
        }
    }

    private var consumersSection: some View {
        Section {
            ForEach(volume.containers, id: \.self) { containerID in
                if let container = resolvedContainer(for: containerID) {
                    NavigationLink {
                        ContainerDetailView(container: container, environmentID: environmentID)
                    } label: {
                        HStack {
                            StatusIcon(status: container.status, isLive: container.isRunning)
                            VStack(alignment: .leading) {
                                Text(container.displayName).font(.headline)
                                Text(verbatim: containerID)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    LabeledContent("Unavailable container") {
                        MonospacedValue(value: containerID).textSelection(.enabled)
                    }
                }
            }
        } header: {
            Text(verbatim: "Consumers (\(volume.containers.count))")
        }
    }

    @ViewBuilder
    private var labelsSection: some View {
        if !volume.labels.isEmpty {
            Section("Labels") {
                ForEach(volume.labels.keys.sorted(), id: \.self) { key in
                    LabeledContent(key) {
                        Text(volume.labels[key] ?? "")
                            .monospaced()
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var optionsSection: some View {
        if !volume.options.isEmpty {
            Section("Options") {
                ForEach(volume.options.keys.sorted(), id: \.self) { key in
                    LabeledContent(key) {
                        Text(volume.options[key] ?? "")
                            .monospaced()
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var volumeMetadata: [ResourceMetadataItem] {
        [
            ResourceMetadataItem(label: "Driver", value: volume.driver, systemImage: "gearshape"),
            ResourceMetadataItem(label: "Scope", value: volume.scope.capitalized, systemImage: "scope"),
            ResourceMetadataItem(label: "Created", value: volume.createdAt, systemImage: "calendar"),
            ResourceMetadataItem(
                label: "Size", value: sizeBytes?.byteString ?? (loadingSize ? "Loading" : "Unavailable"),
                systemImage: "internaldrive"),
        ]
    }

    private func resolvedContainer(for id: String) -> ContainerSummary? {
        resolvedContainersByID[id]
            ?? resolvedContainersByID.values.first { container in
                container.id.hasPrefix(id) || id.hasPrefix(container.id)
            }
    }

    private func loadConsumers() async {
        guard let client = manager.client, let cached = manager.cached, !volume.containers.isEmpty else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "containers")
            guard
                let containers = try await cached.getAllPages(
                    path: path,
                    elementType: ContainerSummary.self,
                    policy: .containersList,
                    envID: environmentID,
                    fetchPage: { start, limit in
                        let response = try await client.containers.list(
                            envID: environmentID,
                            query: .init(start: start, limit: limit)
                        )
                        return ResourcePage(items: response.data, pagination: response.pagination)
                    }
                )
            else { return }
            resolvedContainersByID = Dictionary(uniqueKeysWithValues: containers.map { ($0.id, $0) })
        } catch {
            // Preserve stable container IDs as fallbacks when resolution fails.
        }
    }

    private func loadSize() async {
        guard let client = manager.client, sizeBytes == nil, !loadingSize else { return }
        loadingSize = true
        defer { loadingSize = false }
        do {
            let path = client.rest.environmentPath(environmentID, "volumes/sizes")
            let sizes: [VolumeSizeInfo] = try await client.rest.get(path)
            if let match = sizes.first(where: { $0.name == volume.name }) {
                sizeBytes = match.size
            } else {
                sizeBytes = 0
            }
        } catch {
            // Slow / unsupported on some hosts — leave as `—`.
        }
    }

    private func deleteVolume() async {
        guard let client = manager.client else { return }
        do {
            try await client.volumes.remove(envID: environmentID, name: volume.name)
            if let cached = manager.cached {
                await cached.invalidate(
                    envID: environmentID,
                    paths: [
                        client.rest.environmentPath(environmentID, "volumes"),
                        client.rest.environmentPath(environmentID, "volumes/sizes"),
                        client.rest.environmentPath(environmentID, "volumes/*"),
                    ])
            }
            mutationStore.markChanged(kind: .volumes, envID: environmentID)
            showToast(.success("Volume deleted"))
            dismiss()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

struct CreateVolumeView: View {
    private enum DriverMode: String {
        case local
        case custom
    }

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let environmentID: EnvironmentID
    let onSuccess: () async -> Void

    @State private var name = ""
    @State private var driverMode = DriverMode.local
    @State private var customDriver = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var driver: String {
        switch driverMode {
        case .local:
            return "local"
        case .custom:
            return customDriver.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var canCreate: Bool {
        !name.isEmpty && !isLoading && (driverMode == .local || !driver.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Volume Details") {
                    FormTextField(
                        title: "Name",
                        placeholder: "app-data",
                        text: $name,
                        autocapitalization: .never,
                        autocorrectionDisabled: true,
                        helper: "Use a stable name so containers can mount this volume later."
                    )
                    FormPicker(
                        title: "Driver",
                        selection: $driverMode,
                        helper: driverMode == .local
                            ? "Use local unless your Docker host has a volume driver plugin."
                            : "Enter the exact Docker volume driver plugin name."
                    ) {
                        Text("Local").tag(DriverMode.local)
                        Text("Custom driver").tag(DriverMode.custom)
                    }
                    if driverMode == .custom {
                        FormTextField(
                            title: "Custom Driver",
                            placeholder: "driver-name",
                            text: $customDriver,
                            autocapitalization: .never,
                            autocorrectionDisabled: true
                        )
                    }
                }
                if let error = errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Create Volume")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                AppToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await createVolume() } }
                        .disabled(!canCreate)
                }
            }
        }
    }

    private func createVolume() async {
        guard let client = manager.client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let body = ["name": name, "driver": driver]
            let path = client.rest.environmentPath(environmentID, "volumes")
            // Same decoder bypass as listVolumes — create returns the Volume too.
            _ = try await client.transport.rawRequest(path, method: "POST", body: body)
            if let cached = manager.cached {
                await cached.invalidate(
                    envID: environmentID,
                    paths: [
                        client.rest.environmentPath(environmentID, "volumes"),
                        client.rest.environmentPath(environmentID, "volumes/sizes"),
                        client.rest.environmentPath(environmentID, "volumes/*"),
                    ])
            }
            mutationStore.markChanged(kind: .volumes, envID: environmentID)
            showToast(.success("Volume created"))
            await onSuccess()
            dismiss()
        } catch { errorMessage = friendlyErrorMessage(error) }
    }
}
