import SwiftUI
import Arcane

struct VolumesView: View {
    private static let pageSize = 50

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(PinnedItemsStore.self) private var pinnedStore
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    let environmentID: EnvironmentID
    let environmentName: String

    @Namespace private var heroTransition

    @State private var volumes: [Volume] = []
    @State private var sizes: [String: Int64] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var actionErrorMessage: String?
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var showCreateSheet = false
    @State private var pendingDestructive: VolumeDestructive?
    @State private var showFilterSheet = false
    @State private var scopeFilter = VolumeScopeFilter.all
    @State private var sortOrder = ListSortOrder.ascending
    @State private var currentPage = 1
    @State private var hasMore = false
    @State private var isLoadingMore = false
    @State private var loadGeneration = 0
    @State private var sections: [StableListSection<String, Volume>] = []
    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var isBulkRunning = false
    @State private var bulkRunningActionID: String?

    private enum VolumeScopeFilter: String, CaseIterable {
        case all = "All", local = "Local", global = "Global"
    }

    /// Prune and per-volume delete share one `.deleteConfirmation` cover
    /// (one full-screen cover per view).
    private enum VolumeDestructive {
        case prune
        case delete(Volume)
        case bulkDelete([String])
    }

    private var activeFilterCount: Int { scopeFilter != .all ? 1 : 0 }

    private var pinnedIDs: Set<String> {
        pinnedStore.pinnedIDs(kind: .volume, envID: environmentID)
    }

    /// Filters + sorts once and partitions in a single pass. Pure — reads the
    /// current inputs and returns the grouped sections without touching state.
    private func computeSections() -> [StableListSection<String, Volume>] {
        let query = debouncedSearchText
        let filtered = volumes.filter { volume in
            let matchesSearch = query.isEmpty ||
                volume.name.localizedCaseInsensitiveContains(query) ||
                volume.driver.localizedCaseInsensitiveContains(query)
            let matchesScope = scopeFilter == .all
                || (scopeFilter == .local && volume.scope.lowercased() == "local")
                || (scopeFilter == .global && volume.scope.lowercased() != "local")
            return matchesSearch && matchesScope
        }
        .sorted {
            sortOrder.areInIncreasingOrder($0.name, $1.name)
        }
        let pinned: Set<String> = pinnedIDs
        var pinnedItems: [Volume] = []
        var used: [Volume] = []
        var unused: [Volume] = []
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
            .init(id: "unused", title: "Unused", items: unused)
        ]
    }

    /// Refresh the cached `sections`. Called only when an input that affects
    /// grouping actually changes (search settle, sort, filter, pins, or the
    /// source list) — never on every body evaluation. Volume sizes are read
    /// per-row and don't affect grouping, so they don't trigger a rebuild.
    private func rebuildSections(animated: Bool = false) {
        let new = computeSections()
        if animated {
            withAnimation(Motion.reduced(Motion.reflow, reduceMotion: reduceMotion)) { sections = new }
        } else {
            sections = new
        }
        pruneSelection(validIDs: Set(volumes.map(\.id)))
    }

    private var mutationVersion: Int {
        mutationStore.version(kind: .volumes, envID: environmentID)
    }

    /// Per-section item counts — drives the List's implicit reflow animation so a
    /// programmatic insert/remove animates too.
    private var sectionCounts: [Int] { sections.map(\.items.count) }

    private var selectedVolumes: [Volume] {
        volumes.filter { selection.contains($0.id) }
    }

    private var selectedVolumeNames: [String] {
        selectedVolumes.map(\.name)
    }

    private var bulkPrimaryItem: ActionButtonItem? {
        guard !selection.isEmpty else { return nil }
        return ActionButtonItem(
            id: "bulk-delete",
            title: "Delete",
            systemImage: "trash",
            tint: .red
        ) {
            pendingDestructive = .bulkDelete(selectedVolumeNames)
        }
    }

    var body: some View {
        LoadingCrossfade(showSkeleton: isLoading && volumes.isEmpty) {
            SkeletonListLoadingView()
        } content: {
            if let error = errorMessage, volumes.isEmpty {
                ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if volumes.isEmpty {
                ContentUnavailableView {
                    Label("No Volumes", systemImage: "externaldrive")
                } description: {
                    Text("No volumes found in this environment.")
                } actions: {
                    Button("Create Volume") { showCreateSheet = true }
                }
            } else {
                List(selection: $selection) {
                    StableSectionedList(sections) { volume in
                        volumeLink(volume)
                    }

                    if hasMore {
                        SkeletonListRow()
                            .skeletonShimmer()
                            .onAppear {
                                Task { await loadMore() }
                            }
                    }
                }
                .listStyle(.insetGrouped)
                .environment(\.editMode, .constant(isSelecting ? EditMode.active : EditMode.inactive))
                .motionAwareAnimation(Motion.reflow, value: sectionCounts)
            }
        }
        .navigationTitle("Volumes")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search volumes")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    if !isSelecting {
                        Button {
                            enterSelectionMode()
                        } label: {
                            Label("Select", systemImage: "checklist")
                        }
                        Divider()
                    }
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(ListSortOrder.allCases) { order in
                            Label(order.title, systemImage: order.systemImage).tag(order)
                        }
                    }
                    Button {
                        showFilterSheet = true
                    } label: {
                        Label(
                            activeFilterCount > 0 ? "Filter (\(activeFilterCount))" : "Filter…",
                            systemImage: "line.3.horizontal.decrease.circle"
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More options")
            }
            if isSelecting {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        exitSelectionMode()
                    }
                }
            }
            if !isSelecting {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showCreateSheet = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Create volume")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(role: .destructive) { pendingDestructive = .prune } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .accessibilityLabel("Prune unused volumes")
                }
            }
        }
        .task { await loadVolumes(reset: true) }
        .refreshable { await loadVolumes(reset: true, refresh: true) }
        .debounce(searchText, for: .milliseconds(200), into: $debouncedSearchText)
        .navigationDestination(for: Volume.self) { volume in
            VolumeDetailView(volume: volume, environmentID: environmentID)
                .pageEntranceFromTop()
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateVolumeView(environmentID: environmentID) {}
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .deleteConfirmation(item: $pendingDestructive) { action in
            switch action {
            case .prune:
                return DeleteConfirmationConfig(
                    title: "Prune Unused Volumes",
                    message: "All unused volumes will be permanently deleted.",
                    icon: "trash",
                    actions: [DeleteConfirmationAction(title: "Prune") {
                        Task { await pruneVolumes() }
                    }]
                )
            case .delete(let volume):
                return DeleteConfirmationConfig(
                    title: "Delete Volume",
                    message: "Delete “\(volume.name)”? This cannot be undone.",
                    icon: "trash",
                    actions: [DeleteConfirmationAction(title: "Delete") {
                        Task { await deleteVolume(volume) }
                    }]
                )
            case .bulkDelete(let names):
                return DeleteConfirmationConfig(
                    title: "Delete Volumes",
                    message: "Delete \(names.count) selected volume" +
                        "\(names.count == 1 ? "" : "s")? This cannot be undone.",
                    icon: "trash",
                    actions: [DeleteConfirmationAction(title: "Delete") {
                        Task { await bulkDeleteVolumes(names: names) }
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
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showFilterSheet = false }
                    }
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: mutationVersion) { _, _ in
            Task { await loadVolumes(reset: true, refresh: true) }
        }
        .onChange(of: debouncedSearchText) { rebuildSections() }
        .onChange(of: scopeFilter) { rebuildSections() }
        .onChange(of: sortOrder) { rebuildSections(animated: true) }
        .onChange(of: pinnedIDs) { rebuildSections() }
        .morphingActions(
            primary: bulkPrimaryItem,
            runningItemID: bulkRunningActionID,
            isDisabled: isBulkRunning,
            resourceName: "\(selection.count) selected",
            active: isSelecting && !selection.isEmpty
        )
    }

    private func volumeLink(_ volume: Volume) -> some View {
        let isPinned = pinnedIDs.contains(volume.id)
        return NavigationLink(value: volume) {
            VolumeRow(volume: volume, size: sizes[volume.name], isPinned: isPinned)
        }
        .matchedTransitionSource(id: volume.id, in: heroTransition)
        .contextMenu {
            if !isSelecting {
                Button {
                    togglePin(volume)
                } label: {
                    Label(isPinned ? "Unpin" : "Pin",
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
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if !isSelecting {
                Button {
                    togglePinAfterSwipe(volume)
                } label: {
                    Label(isPinned ? "Unpin" : "Pin",
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

    private func togglePinAfterSwipe(_ volume: Volume) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            togglePin(volume)
        }
    }

    private func togglePin(_ volume: Volume) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pinnedStore.togglePin(volume.id, kind: .volume, envID: environmentID)
        }
    }

    private func volumePreview(_ volume: Volume) -> some View {
        var badges: [RowPreviewCard.PreviewBadge] = []
        badges.append(.init(text: volume.inUse ? "In Use" : "Unused",
                            color: volume.inUse ? .green : .secondary))
        var details: [RowPreviewCard.PreviewDetail] = [
            .init(icon: "gearshape", label: "Driver", value: volume.driver),
            .init(icon: "globe", label: "Scope", value: volume.scope.capitalized)
        ]
        if let size = sizes[volume.name], size > 0 {
            details.insert(.init(icon: "internaldrive", label: "Size", value: size.byteString), at: 0)
        }
        if !volume.mountpoint.isEmpty {
            details.append(.init(icon: "folder", label: "Mount Point", value: volume.mountpoint))
        }
        return RowPreviewCard(
            icon: "externaldrive.fill",
            iconColor: .orange,
            title: volume.name,
            badges: badges,
            details: details
        )
    }

    private func loadVolumes(reset: Bool, refresh: Bool = false) async {
        guard let client = manager.client else { return }
        loadGeneration += 1
        let generation = loadGeneration
        let requestedPage = reset ? 1 : currentPage + 1
        let start = max(0, (requestedPage - 1) * Self.pageSize)
        if volumes.isEmpty { isLoading = true }
        errorMessage = nil
        defer {
            if loadGeneration == generation {
                isLoading = false
            }
        }
        do {
            // `PaginatedResponse<Volume>` is Decodable-only, so we can't route
            // it through the cache layer (which requires Codable). Fetch
            // directly through the SDK.
            let response = try await client.volumes.list(
                envID: environmentID,
                query: .init(start: start, limit: Self.pageSize)
            )
            applyVolumesPage(response, reset: reset, generation: generation)
        } catch {
            guard loadGeneration == generation else { return }
            errorMessage = friendlyErrorMessage(error)
        }
        if reset || sizes.isEmpty {
            await loadSizes(refresh: refresh)
        }
    }

    private func applyVolumesPage(_ response: PaginatedResponse<Volume>, reset: Bool, generation: Int) {
        guard loadGeneration == generation else { return }
        if reset {
            volumes = response.data
        } else {
            let existing = Set(volumes.map(\.id))
            volumes.append(contentsOf: response.data.filter { !existing.contains($0.id) })
        }
        currentPage = max(Int(response.pagination.currentPage), 1)
        hasMore = response.pagination.currentPage < response.pagination.totalPages
        rebuildSections()
    }

    private func loadSizes(refresh: Bool = false) async {
        guard let client = manager.client, let cached = manager.cached else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "volumes/sizes")
            if let entries: [VolumeSizeInfo] = try await cached.get(
                path, as: [VolumeSizeInfo].self, policy: .volumes,
                envID: environmentID, refresh: refresh,
                onFresh: { fresh in
                    sizes = Dictionary(fresh.map { ($0.name, $0.size) }, uniquingKeysWith: { _, new in new })
                }
            ) {
                sizes = Dictionary(entries.map { ($0.name, $0.size) }, uniquingKeysWith: { _, new in new })
            }
        } catch {
            // Slow / unsupported on some hosts — leave sizes blank silently.
        }
    }

    private func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        await loadVolumes(reset: false)
    }

    private func deleteVolume(_ volume: Volume) async {
        guard let client = manager.client else { return }
        do {
            try await client.volumes.remove(envID: environmentID, name: volume.name)
            withAnimation {
                volumes.removeAll { $0.name == volume.name }
                rebuildSections()
            }
            await invalidateVolumeCaches()
            mutationStore.markChanged(kind: .volumes, envID: environmentID)
        } catch {
            actionErrorMessage = friendlyErrorMessage(error)
        }
    }

    private func pruneVolumes() async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "volumes/prune")
            let _: DataResponse<String> = try await client.rest.post(path, body: String?.none)
            await invalidateVolumeCaches()
            mutationStore.markChanged(kind: .volumes, envID: environmentID)
        } catch {
            actionErrorMessage = friendlyErrorMessage(error)
        }
    }

    private func bulkDeleteVolumes(names: [String]) async {
        guard let client = manager.client else { return }
        isBulkRunning = true
        bulkRunningActionID = "bulk-delete"
        defer {
            isBulkRunning = false
            bulkRunningActionID = nil
        }
        let result = await BulkActionRunner.run(ids: names) { name in
            try await client.volumes.remove(envID: environmentID, name: name)
        }
        let failedNames = Set(result.failed.map(\.id))
        let removedNames = Set(names.filter { !failedNames.contains($0) })
        withAnimation(Motion.reduced(Motion.reflow, reduceMotion: reduceMotion)) {
            volumes.removeAll { removedNames.contains($0.name) }
            for name in removedNames {
                sizes.removeValue(forKey: name)
            }
            rebuildSections()
        }
        await invalidateVolumeCaches()
        mutationStore.markChanged(kind: .volumes, envID: environmentID)
        exitSelectionMode()
        if result.failed.isEmpty {
            showToast(.success("Deleted \(result.succeeded) volume\(result.succeeded == 1 ? "" : "s")"))
            ReviewPrompter.shared.recordSuccess()
        } else {
            showToast(.error("\(result.failed.count) of \(names.count) failed"))
        }
    }

    private func invalidateVolumeCaches() async {
        guard let cached = manager.cached, let client = manager.client else { return }
        await cached.invalidate(envID: environmentID, paths: [
            client.rest.environmentPath(environmentID, "volumes"),
            client.rest.environmentPath(environmentID, "volumes/sizes"),
            client.rest.environmentPath(environmentID, "volumes/*")
        ])
    }
}

struct UsageBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.teal, in: .circle)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(volume.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
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
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 2)
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

    private enum VolumeRoute: Hashable { case browse, backups }

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "externaldrive.fill")
                        .font(.title)
                        .foregroundStyle(.orange)
                        .frame(width: 56, height: 56)
                        .glassEffectCompat(in: .circle)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(volume.name).font(.title3.bold()).lineLimit(2)
                        Text("Driver: \(volume.driver)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Details") {
                LabeledContent("Driver", value: volume.driver)
                LabeledContent("Scope", value: volume.scope.capitalized)
                if !volume.mountpoint.isEmpty { LabeledContent("Mount Point", value: volume.mountpoint) }
                LabeledContent("Created", value: volume.createdAt)
                HStack {
                    Text("Size")
                    Spacer()
                    if let sizeBytes {
                        Text(sizeBytes.byteString).foregroundStyle(.secondary)
                    } else if loadingSize {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                NavigationLink("Browse Files") {
                    VolumeBrowserView(environmentID: environmentID, volumeName: volume.name)
                }
                NavigationLink("Backups") {
                    VolumeBackupsView(environmentID: environmentID, volumeName: volume.name)
                }
            }

            let labels = volume.labels
            if !labels.isEmpty {
                Section("Labels") {
                    ForEach(Array(labels.keys.sorted()), id: \.self) { key in
                        LabeledContent(key, value: labels[key] ?? "")
                    }
                }
            }

            let options = volume.options
            if !options.isEmpty {
                Section("Options") {
                    ForEach(Array(options.keys.sorted()), id: \.self) { key in
                        LabeledContent(key, value: options[key] ?? "")
                    }
                }
            }

        }
        .listStyle(.insetGrouped)
        .morphingActions(
            primary: ActionButtonItem(
                id: "browse",
                title: "Browse Files",
                systemImage: "folder",
                tint: .accentColor
            ) {
                route = .browse
            },
            inline: [
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
        .task { await loadSize() }
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
                await cached.invalidate(envID: environmentID, paths: [
                    client.rest.environmentPath(environmentID, "volumes"),
                    client.rest.environmentPath(environmentID, "volumes/sizes"),
                    client.rest.environmentPath(environmentID, "volumes/*")
                ])
            }
            mutationStore.markChanged(kind: .volumes, envID: environmentID)
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
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await createVolume() } }
                        .disabled(!canCreate)
                }
            }
        }
    }

    private func createVolume() async {
        guard let client = manager.client else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let body = ["name": name, "driver": driver]
            let path = client.rest.environmentPath(environmentID, "volumes")
            // Same decoder bypass as listVolumes — create returns the Volume too.
            _ = try await client.transport.rawRequest(path, method: "POST", body: body)
            if let cached = manager.cached {
                await cached.invalidate(envID: environmentID, paths: [
                    client.rest.environmentPath(environmentID, "volumes"),
                    client.rest.environmentPath(environmentID, "volumes/sizes"),
                    client.rest.environmentPath(environmentID, "volumes/*")
                ])
            }
            mutationStore.markChanged(kind: .volumes, envID: environmentID)
            await onSuccess(); dismiss()
        } catch { errorMessage = friendlyErrorMessage(error) }
    }
}
