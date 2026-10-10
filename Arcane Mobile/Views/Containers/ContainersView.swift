import Arcane
import SwiftUI

struct ContainersView: View {
    private static let pageSize = 50

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(PinnedItemsStore.self) private var pinnedStore
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.colorScheme) private var colorScheme
    let environmentID: EnvironmentID
    let environmentName: String

    @State private var containers: [ContainerSummary] = []
    @State private var routedContainer: ContainerSummary?
    @State private var routedDetails: ContainerDetails?
    @State private var routeGeneration = 0
    @State private var router = QuickActionRouter.shared
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var pendingDestructive: ContainerDestructive?
    @State private var showCreateContainer = false
    @State private var showCompose = false
    @State private var showFilterSheet = false
    @State private var stateFilter = ContainerStateFilter.all
    @State private var updateFilter = ResourceUpdateFilter.all
    @State private var showHidden = false
    @State private var labelFilter = ""
    @State private var debouncedLabelFilter = ""
    @State private var sortOrder = ListSortOrder.ascending
    @State private var sections: [StableListSection<String, ContainerSummary>] = []

    @State private var logsTarget: ContainerSummary?
    @State private var terminalTarget: ContainerSummary?
    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var isBulkRunning = false
    @State private var bulkRunningActionID: String?
    @State private var pagination = ProgressivePaginationState()
    @State private var isLoadingMore = false
    @State private var loadMoreError: String?

    /// Prune and per-container remove share one `.deleteConfirmation` cover
    /// (one full-screen cover per view).
    private enum ContainerDestructive {
        case prune
        case remove(ContainerSummary)
        case bulkRemove([String])
    }

    private enum ContainerBulkAction {
        case start
        case stop
        case restart

        var id: String {
            switch self {
            case .start: return "bulk-start"
            case .stop: return "bulk-stop"
            case .restart: return "bulk-restart"
            }
        }

        var title: String {
            switch self {
            case .start: return "Start"
            case .stop: return "Stop"
            case .restart: return "Restart"
            }
        }

        var summaryVerb: String {
            switch self {
            case .start: return "Started"
            case .stop: return "Stopped"
            case .restart: return "Restarted"
            }
        }

        var systemImage: String {
            switch self {
            case .start: return "play.fill"
            case .stop: return "stop.fill"
            case .restart: return "arrow.clockwise"
            }
        }

        var tint: Color {
            switch self {
            case .start: return .green
            case .stop: return .red
            case .restart: return .orange
            }
        }

        func applies(to container: ContainerSummary) -> Bool {
            switch self {
            case .start: return !container.isRunning
            case .stop, .restart: return container.isRunning
            }
        }
    }

    private var activeFilterCount: Int {
        var count = stateFilter != .all ? 1 : 0
        if updateFilter != .all { count += 1 }
        if showHidden { count += 1 }
        if !labelFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { count += 1 }
        return count
    }

    private var pinnedIDs: Set<String> {
        pinnedStore.pinnedIDs(kind: .container, envID: environmentID)
    }

    /// Filters + sorts once and partitions in a single pass. Pure — reads the
    /// current inputs and returns the grouped sections without touching state.
    private func computeSections() -> [StableListSection<String, ContainerSummary>] {
        let query = debouncedSearchText
        let filtered = containers.filter { container in
            let matchesSearch =
                query.isEmpty || container.names.contains(where: { $0.localizedCaseInsensitiveContains(query) })
                || container.image.localizedCaseInsensitiveContains(query)
            let matchesState =
                stateFilter == .all
                || (stateFilter == .running && container.isRunning)
                || (stateFilter == .stopped && !container.isRunning)
            let matchesUpdate = updateFilter.matches(hasUpdate: container.hasAvailableUpdate)
            let matchesHidden = showHidden || container.hidden != true
            return matchesSearch && matchesState && matchesUpdate && matchesHidden
        }
        .sorted {
            sortOrder.areInIncreasingOrder($0.displayName, $1.displayName)
        }
        let pinned: Set<String> = pinnedIDs
        var pinnedItems: [ContainerSummary] = []
        var running: [ContainerSummary] = []
        var stopped: [ContainerSummary] = []
        for container in filtered {
            if pinned.contains(container.id) {
                pinnedItems.append(container)
            } else if container.isRunning {
                running.append(container)
            } else {
                stopped.append(container)
            }
        }
        return [
            .init(id: "pinned", title: "Pinned", items: pinnedItems),
            .init(id: "running", title: "Running", items: running),
            .init(id: "stopped", title: "Stopped", items: stopped),
        ]
    }

    /// Refresh the cached `sections`. Called only when an input that affects
    /// grouping actually changes (search settle, sort, filter, pins, or the
    /// source list) — never on every body evaluation.
    private func rebuildSections() {
        sections = computeSections()
        pruneSelection(validIDs: Set(containers.map(\.id)))
    }

    private var mutationVersion: Int {
        mutationStore.version(kind: .containers, envID: environmentID)
    }

    /// Per-section item counts — drives the List's implicit reflow animation so a
    /// programmatic insert/remove (start/stop/remove/prune) animates too.

    private var selectedContainers: [ContainerSummary] {
        containers.filter { selection.contains($0.id) }
    }

    private var selectedContainerIDs: [String] {
        selectedContainers.map(\.id)
    }

    private var bulkPrimaryAction: ContainerBulkAction? {
        let selected = selectedContainers
        guard !selected.isEmpty else { return nil }
        if selected.allSatisfy({ !$0.isRunning }) { return .start }
        if selected.allSatisfy(\.isRunning) { return .stop }
        return .restart
    }

    private var bulkInlineActions: [ContainerBulkAction] {
        let selected = selectedContainers
        guard !selected.isEmpty, let primary = bulkPrimaryAction else { return [] }
        return [ContainerBulkAction.start, .stop, .restart].filter { action in
            action.id != primary.id && selected.contains(where: action.applies)
        }
    }

    private var bulkPrimaryItem: ActionButtonItem? {
        guard let action = bulkPrimaryAction else { return nil }
        return bulkActionItem(action)
    }

    private var bulkInlineItems: [ActionButtonItem] {
        bulkInlineActions.map(bulkActionItem)
    }

    private var bulkOverflowItems: [ActionButtonItem] {
        guard !selectedContainerIDs.isEmpty else { return [] }
        var items: [ActionButtonItem] = []
        let updatable = selectedContainers.filter(\.hasAvailableUpdate)
        if !updatable.isEmpty {
            items.append(
                ActionButtonItem(
                    id: "bulk-update", title: "Update (\(updatable.count))", systemImage: "arrow.up.circle.fill",
                    tint: .blue
                ) {
                    startBulkUpdate(containers: updatable)
                })
        }
        if manager.serverCapabilities?.mode == .rbac,
            manager.permissions.has(Permission.Containers.read, in: environmentID)
        {
            items.append(
                ActionButtonItem(
                    id: "generate-compose", title: "Generate Compose", systemImage: "doc.text", tint: .accentColor
                ) { showCompose = true })
        }
        items.append(
            ActionButtonItem(
                id: "bulk-delete",
                title: "Remove",
                systemImage: "trash",
                tint: .red
            ) {
                pendingDestructive = .bulkRemove(selectedContainerIDs)
            }
        )
        return items
    }

    var body: some View {
        LoadingCrossfade(
            showSkeleton: isLoading && containers.isEmpty,
            animatesTransition: false
        ) {
            ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } content: {
            if let error = errorMessage, containers.isEmpty {
                ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if containers.isEmpty {
                ContentUnavailableView {
                    Label("No Containers", systemImage: "cube.box")
                } description: {
                    Text("No containers found in this environment.")
                } actions: {
                    Button("Refresh") {
                        Task { await loadContainers() }
                    }
                }
            } else {
                List(selection: BulkListSelection.binding($selection, isSelecting: isSelecting)) {
                    StableSectionedList(
                        sections,
                        preferredHeaderAccessorySectionID: "running",
                        headerAccessory: { _ in
                            ResourceCountLabel(
                                loadedCount: containers.count,
                                totalCount: pagination.totalItems,
                                hasMore: pagination.hasMore
                            )
                        }
                    ) { container in
                        containerLink(container)
                    }

                    PaginatedListFooter(
                        hasMore: pagination.hasMore,
                        loadMoreError: loadMoreError,
                        onRetry: { Task { await loadMore() } },
                        onLoadMore: { Task { await loadMore() } }
                    )
                }
                .listStyle(.insetGrouped)
                .environment(\.editMode, .constant(isSelecting ? EditMode.active : EditMode.inactive))

            }
        }
        .navigationTitle("Containers")
        .navigationBarTitleDisplayMode(.large)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search containers"
        )
        .toolbar {
            if !isSelecting {
                AppToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        if manager.permissions.has(Permission.Containers.create, in: environmentID) {
                            Button("Create Container", systemImage: "plus") { showCreateContainer = true }
                        }
                        Button {
                            enterSelectionMode()
                        } label: {
                            Label("Select", systemImage: "checklist")
                        }
                        Divider()
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
                        Divider()
                        Button(role: .destructive) {
                            pendingDestructive = .prune
                        } label: {
                            DestructiveLabel(text: "Prune Stopped Containers")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .appAccentToolbarSymbol()
                    }
                    .accessibilityLabel("More options")
                }
            }
            if #available(iOS 26, *) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            if isSelecting {
                AppToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        exitSelectionMode()
                    }
                }
            }
        }
        .deleteConfirmation(item: $pendingDestructive) { action in
            switch action {
            case .prune:
                return DeleteConfirmationConfig(
                    title: "Prune Stopped Containers",
                    message: "Remove all stopped containers. This cannot be undone.",
                    icon: "trash",
                    actions: [
                        DeleteConfirmationAction(title: "Prune") {
                            Task { await pruneContainers() }
                        }
                    ]
                )
            case .remove(let container):
                return DeleteConfirmationConfig(
                    title: "Remove Container",
                    message: "Remove “\(container.displayName)”? This permanently deletes the container.",
                    icon: "trash",
                    actions: [
                        DeleteConfirmationAction(title: "Remove") {
                            Task { await removeContainer(container) }
                        }
                    ]
                )
            case .bulkRemove(let ids):
                return DeleteConfirmationConfig(
                    title: "Remove Containers",
                    message: "Remove \(ids.count) selected container"
                        + "\(ids.count == 1 ? "" : "s")? This cannot be undone.",
                    icon: "trash",
                    actions: [
                        DeleteConfirmationAction(title: "Remove") {
                            Task { await bulkRemoveContainers(ids: ids) }
                        }
                    ]
                )
            }
        }
        .sheet(isPresented: $showCreateContainer) {
            ContainerConfigurationView(environmentID: environmentID) { id in
                routedDetails = nil
                routedContainer = ContainerSummary(id: id, image: "", imageId: "", state: "", status: "")
            }
        }
        .sheet(isPresented: $showCompose) {
            ContainerComposeView(environmentID: environmentID, containerIDs: selectedContainerIDs)
        }
        .sheet(isPresented: $showFilterSheet) {
            NavigationStack {
                Form {
                    Section("State") {
                        Picker("State", selection: $stateFilter) {
                            ForEach(ContainerStateFilter.allCases, id: \.self) { filter in
                                Text(filter.rawValue).tag(filter)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    Section("Updates") {
                        Picker("Updates", selection: $updateFilter) {
                            ForEach(ResourceUpdateFilter.allCases) { filter in
                                Text(filter.title).tag(filter)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    Section("Visibility") {
                        Toggle("Show hidden", isOn: $showHidden)
                        TextField("Label (key or key=value)", text: $labelFilter)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
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
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $logsTarget) { container in
            LogsView(
                title: container.displayName,
                logStream: {
                    manager.client?.boundedContainerLogs(
                        envID: environmentID,
                        id: container.id,
                        timestamps: true
                    )
                }
            )
        }
        .fullScreenCover(item: $terminalTarget) { container in
            ContainerTerminalView(container: container, environmentID: environmentID)
        }
        .task { await loadContainers() }
        .refreshable { await loadContainers() }
        .debounce(searchText, for: .milliseconds(200), into: $debouncedSearchText)
        .debounce(labelFilter, for: .milliseconds(500), into: $debouncedLabelFilter)
        .navigationDestination(for: ContainerSummary.self) { container in
            ContainerDetailView(container: container, environmentID: environmentID)
        }
        .navigationDestination(item: $routedContainer) { container in
            ContainerDetailView(container: container, environmentID: environmentID, initialDetails: routedDetails)
        }
        .onChange(of: router.pendingRoute, initial: true) { _, _ in
            Task { await consumeContainerRoute() }
        }
        .onChange(of: mutationVersion) { _, _ in
            Task { await loadContainers() }
        }
        .onChange(of: debouncedSearchText) {
            Task { await loadContainers() }
        }
        .onChange(of: stateFilter) { rebuildSections() }
        .onChange(of: updateFilter) { rebuildSections() }
        .onChange(of: showHidden) {
            rebuildSections()
            Task { await loadContainers() }
        }
        .onChange(of: debouncedLabelFilter) {
            Task { await loadContainers() }
        }
        .onChange(of: sortOrder) { rebuildSections() }
        .onChange(of: pinnedIDs) { rebuildSections() }
        .resourceActionsToolbar(
            primary: bulkPrimaryItem,
            secondary: bulkInlineItems,
            overflow: bulkOverflowItems,
            runningItemID: bulkRunningActionID,
            isDisabled: isBulkRunning,
            resourceName: "\(selection.count) selected",
            active: isSelecting && !selection.isEmpty
        )
    }

    private func containerLink(_ container: ContainerSummary) -> some View {
        let isPinned = pinnedIDs.contains(container.id)
        return NavigationLink(value: container) {
            ContainerRow(container: container, isPinned: isPinned)
        }
        .contextMenu {
            if !isSelecting {
                Button {
                    togglePin(container)
                } label: {
                    Label(
                        isPinned ? "Unpin" : "Pin",
                        systemImage: isPinned ? "pin.slash.fill" : "pin.fill")
                }
                containerMenuActions(for: container)
            }
        } preview: {
            if !isSelecting {
                containerPreview(container)
                    .environment(manager)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if !isSelecting {
                Button {
                    togglePinAfterSwipe(container)
                } label: {
                    Label(
                        isPinned ? "Unpin" : "Pin",
                        systemImage: isPinned ? "pin.slash.fill" : "pin.fill")
                }
                .tint(.yellow)
                Button {
                    logsTarget = container
                } label: {
                    Label("Logs", systemImage: "text.alignleft")
                }
                .tint(.blue)
            }
        }
        .swipeActions(edge: .trailing) {
            if !isSelecting {
                containerSwipeActions(for: container)
            }
        }
    }

    private func bulkActionItem(_ action: ContainerBulkAction) -> ActionButtonItem {
        ActionButtonItem(
            id: action.id,
            title: action.title,
            systemImage: action.systemImage,
            tint: action.tint
        ) {
            Task { await runBulkAction(action) }
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

    private func togglePinAfterSwipe(_ container: ContainerSummary) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            togglePin(container)
        }
    }

    private func togglePin(_ container: ContainerSummary) {
        HapticsManager.light()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pinnedStore.togglePin(container.id, kind: .container, envID: environmentID)
        }
    }

    @ViewBuilder
    private func containerMenuActions(for container: ContainerSummary) -> some View {
        if container.hasAvailableUpdate,
            manager.permissions.has(Permission.Containers.autoUpdate, in: environmentID)
        {
            Button {
                startBulkUpdate(containers: [container])
            } label: {
                Label("Update", systemImage: "arrow.up.circle.fill")
            }
        }
        Button {
            logsTarget = container
        } label: {
            Label("Logs", systemImage: "text.alignleft")
        }
        if container.isRunning {
            Button {
                terminalTarget = container
            } label: {
                Label("Terminal", systemImage: "terminal")
            }
        }
        if container.isRunning {
            Button(role: .destructive) {
                Task { await stopContainer(container) }
            } label: {
                DestructiveLabel(text: "Stop", systemImage: "stop.fill")
            }
            .tint(.red)
            Button {
                Task { await restartContainer(container) }
            } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }
        } else {
            Button {
                Task { await startContainer(container) }
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            Button(role: .destructive) {
                pendingDestructive = .remove(container)
            } label: {
                DestructiveLabel(text: "Remove")
            }
            .tint(.red)
        }
    }

    private func containerPreview(_ container: ContainerSummary) -> some View {
        var details: [RowPreviewCard.PreviewDetail] = [
            .init(icon: "photo", label: "Image", value: container.image),
            .init(icon: "info.circle", label: "Status", value: container.status),
        ]
        if let firstName = container.names.first {
            let trimmed = firstName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !trimmed.isEmpty {
                details.append(.init(icon: "tag", label: "Name", value: trimmed))
            }
        }
        return RowPreviewCard(
            icon: "cube.box.fill",
            iconColor: container.isRunning ? .green : .secondary,
            iconUrl: container.themedIconUrl(for: colorScheme),
            title: container.displayName,
            badges: [
                .init(
                    text: container.isRunning ? "Running" : "Stopped",
                    color: container.isRunning ? .green : .secondary)
            ],
            details: details
        )
    }

    @ViewBuilder
    private func containerSwipeActions(for container: ContainerSummary) -> some View {
        if container.isRunning {
            Button(role: .destructive) {
                Task { await stopContainer(container) }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            Button {
                Task { await restartContainer(container) }
            } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }
            .tint(.orange)
        } else {
            Button {
                Task { await startContainer(container) }
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            .tint(.green)
        }
    }

    private func removeContainer(_ container: ContainerSummary) async {
        guard let client = manager.client else { return }
        do {
            try await client.containers.delete(envID: environmentID, id: container.id)
            containers.removeAll { $0.id == container.id }
            rebuildSections()
            await invalidateContainerCaches()
            mutationStore.markChanged(kind: .containers, envID: environmentID)
            showToast(.success("Container removed"))
            ReviewPrompter.shared.recordSuccess()
        } catch {
            showToast(.error("Couldn't remove container"))
        }
    }

    private func loadContainers() async {
        guard let client = manager.client else { return }
        let generation = pagination.reset()
        let start = 0
        isLoadingMore = false
        if containers.isEmpty { isLoading = true }
        errorMessage = nil
        loadMoreError = nil
        defer {
            if pagination.accepts(generation) {
                isLoading = false
            }
        }
        do {
            let trimmedLabel = debouncedLabelFilter.trimmingCharacters(in: .whitespacesAndNewlines)
            let response = try await client.containers.list(
                envID: environmentID,
                query: .init(
                    search: debouncedSearchText.isEmpty ? nil : debouncedSearchText,
                    start: start,
                    limit: Self.pageSize
                ),
                includeHidden: showHidden ? true : nil,
                label: trimmedLabel.isEmpty ? nil : trimmedLabel
            )
            applyContainersPage(
                response,
                reset: true,
                requestedStart: start,
                generation: generation
            )
        } catch {
            guard pagination.accepts(generation) else { return }
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func loadMore() async {
        guard pagination.hasMore, !isLoadingMore, let client = manager.client else { return }
        isLoadingMore = true
        loadMoreError = nil
        let generation = pagination.generation
        let start = pagination.nextStart
        defer {
            if pagination.accepts(generation) {
                isLoadingMore = false
            }
        }
        do {
            let trimmedLabel = debouncedLabelFilter.trimmingCharacters(in: .whitespacesAndNewlines)
            let response = try await client.containers.list(
                envID: environmentID,
                query: .init(
                    search: debouncedSearchText.isEmpty ? nil : debouncedSearchText,
                    start: start,
                    limit: Self.pageSize
                ),
                includeHidden: showHidden ? true : nil,
                label: trimmedLabel.isEmpty ? nil : trimmedLabel
            )
            applyContainersPage(
                response,
                reset: false,
                requestedStart: start,
                generation: generation
            )
        } catch {
            guard pagination.accepts(generation) else { return }
            loadMoreError = friendlyErrorMessage(error)
        }
    }

    private func applyContainersPage(
        _ response: ContainerListResponse,
        reset: Bool,
        requestedStart: Int,
        generation: Int
    ) {
        guard
            pagination.receive(
                pagination: response.pagination,
                itemCount: response.data.count,
                requestedStart: requestedStart,
                requestedLimit: Self.pageSize,
                generation: generation
            )
        else { return }
        containers = PaginationLoader.merge(
            current: containers,
            incoming: response.data,
            reset: reset
        )
        loadMoreError = nil
        rebuildSections()
    }

    private func startContainer(_ container: ContainerSummary) async {
        guard let client = manager.client else { return }
        do {
            try await client.containers.start(envID: environmentID, id: container.id)
            await invalidateContainerCaches()
            mutationStore.markChanged(kind: .containers, envID: environmentID)
            showToast(.success("Container started"))
            ReviewPrompter.shared.recordSuccess()
        } catch {
            showToast(.error("Couldn't start container"))
        }
    }

    private func stopContainer(_ container: ContainerSummary) async {
        guard let client = manager.client else { return }
        do {
            try await client.containers.stop(envID: environmentID, id: container.id)
            await invalidateContainerCaches()
            mutationStore.markChanged(kind: .containers, envID: environmentID)
            showToast(.success("Container stopped"))
            ReviewPrompter.shared.recordSuccess()
        } catch {
            showToast(.error("Couldn't stop container"))
        }
    }

    private func pruneContainers() async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "containers/prune")
            let _: DataResponse<String> = try await client.rest.post(path, body: String?.none)
            await invalidateContainerCaches()
            mutationStore.markChanged(kind: .containers, envID: environmentID)
            showToast(.success("Containers pruned"))
            ReviewPrompter.shared.recordSuccess()
        } catch {
            showToast(.error("Prune failed"))
        }
    }

    private func restartContainer(_ container: ContainerSummary) async {
        guard let client = manager.client else { return }
        do {
            try await client.containers.restart(envID: environmentID, id: container.id)
            await invalidateContainerCaches()
            mutationStore.markChanged(kind: .containers, envID: environmentID)
            showToast(.success("Container restarted"))
            ReviewPrompter.shared.recordSuccess()
        } catch {
            showToast(.error("Couldn't restart container"))
        }
    }

    private func runBulkAction(_ action: ContainerBulkAction) async {
        guard let client = manager.client else { return }
        let ids = selectedContainers.filter(action.applies).map(\.id)
        guard !ids.isEmpty else {
            showToast(.info("No matching containers selected"))
            return
        }
        isBulkRunning = true
        bulkRunningActionID = action.id
        defer {
            isBulkRunning = false
            bulkRunningActionID = nil
        }
        let result = await BulkActionRunner.run(ids: ids) { id in
            switch action {
            case .start:
                try await client.containers.start(envID: environmentID, id: id)
            case .stop:
                try await client.containers.stop(envID: environmentID, id: id)
            case .restart:
                try await client.containers.restart(envID: environmentID, id: id)
            }
        }
        await finishBulkOperation(
            result, total: ids.count,
            successTitle: { count in
                "\(action.summaryVerb) \(count) container\(count == 1 ? "" : "s")"
            })
    }

    private func startBulkUpdate(containers: [ContainerSummary]) {
        let targets = containers.map { DeploymentOperation.UpdateTarget(id: $0.id, name: $0.displayName) }
        guard !targets.isEmpty else { return }
        let started = DeploymentActivityStore.shared.start(
            kind: .containerUpdate,
            envID: environmentID,
            targetID: targets[0].id,
            targetName: targets.count == 1 ? targets[0].name : "\(targets.count) containers",
            environmentName: environmentName,
            manager: manager,
            mutationStore: mutationStore,
            updateTargets: targets
        )
        if started { exitSelectionMode() }
    }

    private func bulkRemoveContainers(ids: [String]) async {
        guard let client = manager.client else { return }
        isBulkRunning = true
        bulkRunningActionID = "bulk-delete"
        defer {
            isBulkRunning = false
            bulkRunningActionID = nil
        }
        let result = await BulkActionRunner.run(ids: ids) { id in
            try await client.containers.delete(envID: environmentID, id: id)
        }
        let failedIDs = Set(result.failed.map(\.id))
        let removedIDs = Set(ids.filter { !failedIDs.contains($0) })
        containers.removeAll { removedIDs.contains($0.id) }
        await finishBulkOperation(
            result, total: ids.count,
            successTitle: { count in
                "Removed \(count) container\(count == 1 ? "" : "s")"
            })
    }

    private func finishBulkOperation(
        _ result: BulkResult,
        total: Int,
        successTitle: (Int) -> String
    ) async {
        await invalidateContainerCaches()
        mutationStore.markChanged(kind: .containers, envID: environmentID)
        rebuildSections()
        exitSelectionMode()
        if result.failed.isEmpty {
            showToast(.success(successTitle(result.succeeded)))
            ReviewPrompter.shared.recordSuccess()
        } else {
            showToast(.error("\(result.failed.count) of \(total) failed"))
        }
    }

    private func invalidateContainerCaches() async {
        guard let cached = manager.cached, let client = manager.client else { return }
        await cached.invalidate(
            envID: environmentID,
            paths: [
                client.rest.environmentPath(environmentID, "containers"),
                client.rest.environmentPath(environmentID, "containers/*"),
            ])
    }
}

struct ContainerRow: View {
    @SwiftUI.Environment(\.colorScheme) private var colorScheme
    let container: ContainerSummary
    var isPinned: Bool = false

    // Docker reports health inside the status string, e.g.
    // "Up 3 hours (healthy)" / "(unhealthy)" / "(health: starting)".
    private var health: (icon: String, color: Color, label: String)? {
        let status = container.status.lowercased()
        if status.contains("unhealthy") { return ("heart.slash.fill", .red, "Unhealthy") }
        if status.contains("health: starting") { return ("heart.fill", .yellow, "Health starting") }
        if status.contains("(healthy)") { return ("heart.fill", .green, "Healthy") }
        return nil
    }

    // The status string with the health parenthetical stripped, leaving the
    // uptime/downtime (e.g. "Up 3 hours", "Exited (0) 2 hours ago").
    private var statusText: String {
        var status = container.status
        for token in ["(healthy)", "(unhealthy)", "(health: starting)"] {
            status = status.replacingOccurrences(of: token, with: "", options: [.caseInsensitive])
        }
        return status.trimmingCharacters(in: .whitespaces)
    }

    var environmentName: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                CachedAsyncImage(url: container.themedIconUrl(for: colorScheme), size: 36) {
                    Image(systemName: "cube.box.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 36, height: 36)
                }
                Circle()
                    .fill(container.isRunning ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 10, height: 10)
                    .offset(x: 2, y: 2)
                    .motionAwareAnimation(Motion.state, value: container.isRunning)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(container.displayName)
                        .font(.body)
                        .lineLimit(nil)
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .accessibilityHidden(true)
                    }
                    if container.hidden == true {
                        Image(systemName: "eye.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Hidden")
                    }
                }
                if !statusText.isEmpty || health != nil {
                    HStack(spacing: 5) {
                        if !statusText.isEmpty {
                            Text(statusText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(nil)
                        }
                        if let health {
                            Image(systemName: health.icon)
                                .font(.subheadline)
                                .foregroundStyle(health.color)
                                .accessibilityLabel(health.label)
                        }
                    }
                }
                UpdateStateBadge(state: ImageUpdateState(info: container.updateInfo))
                FleetEnvironmentLabel(name: environmentName)
            }

            Spacer()

            StatusIcon(status: container.status, isLive: container.isRunning)
        }

        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var parts: [String] = [container.displayName]
        if isPinned { parts.append("pinned") }
        parts.append(container.isRunning ? "running" : "stopped")
        parts.append(container.image)
        parts.append(container.status)
        parts.append(ImageUpdateState(info: container.updateInfo).accessibilityDescription)
        if let environmentName { parts.append(environmentName) }
        return parts.joined(separator: ", ")
    }
}

extension ContainersView {
    /// Resolves the destination independently of the paginated and filtered list.
    fileprivate func consumeContainerRoute() async {
        guard case .authenticated = manager.authState,
            case .container(let envID, let id)? = router.pendingRoute,
            envID == environmentID.rawValue,
            let client = manager.client
        else { return }
        routeGeneration += 1
        let generation = routeGeneration
        let routerGeneration = router.routeGeneration
        let session = manager.cacheSessionIdentity
        router.pendingRoute = nil
        do {
            let details = try await RemoteDataLimits.boundedContainerInspect(
                client: client,
                environmentID: environmentID,
                containerID: id
            )
            try Task.checkCancellation()
            guard generation == routeGeneration,
                routerGeneration == router.routeGeneration,
                session == manager.cacheSessionIdentity,
                client.transport === manager.client?.transport,
                manager.acceptsEnvironmentContext(environmentID)
            else { return }
            routedDetails = details
            routedContainer = details.navigationSummary
        } catch {
            guard generation == routeGeneration,
                routerGeneration == router.routeGeneration,
                session == manager.cacheSessionIdentity,
                client.transport === manager.client?.transport,
                manager.acceptsEnvironmentContext(environmentID)
            else { return }
            showToast(.error(friendlyErrorMessage(error)))
        }
    }
}
