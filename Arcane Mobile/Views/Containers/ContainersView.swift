import Arcane
import SwiftUI

struct ContainersView: View {
    private static let pageSize = 50

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(PinnedItemsStore.self) private var pinnedStore
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(EnvironmentsStore.self) private var environmentsStore
    @SwiftUI.Environment(\.colorScheme) private var colorScheme
    @SwiftUI.Environment(\.scenePhase) private var scenePhase
    let environmentID: EnvironmentID
    let environmentName: String
    /// All Environments preview: list and act on containers from every enabled environment.
    var allEnvironments = false

    @State private var list = EnvironmentPagedList<ContainerSummary>(pageSize: Self.pageSize)
    @State private var routedContainer: EnvironmentItem<ContainerSummary>?
    @State private var routedDetails: ContainerDetails?
    @State private var routeGeneration = 0
    @State private var router = QuickActionRouter.shared
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var pendingDestructive: ContainerDestructive?
    @State private var pendingMaintenanceAction: AllEnvironmentsMaintenanceAction?
    @State private var showCreateContainer = false
    @State private var createEnvironmentID: EnvironmentID?
    @State private var showCompose = false
    @State private var showFilterSheet = false
    @State private var environmentFilter: EnvironmentID?
    @State private var stateFilter = ContainerStateFilter.all
    @State private var updateFilter = ResourceUpdateFilter.all
    @State private var showHidden = false
    @State private var labelFilter = ""
    @State private var debouncedLabelFilter = ""
    @State private var sort = ContainerListSort.nameAscending
    @State private var resourceSamples = ContainerResourceSampleStore()
    @State private var sections: [StableListSection<String, EnvironmentItem<ContainerSummary>>] = []
    /// Pinned row IDs, refreshed in `rebuildSections` (not per row render).
    @State private var pinnedIDs: Set<String> = []

    @State private var logsTarget: EnvironmentItem<ContainerSummary>?
    @State private var terminalTarget: EnvironmentItem<ContainerSummary>?
    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var isBulkRunning = false
    @State private var bulkRunningActionID: String?

    /// Prune and per-container remove share one `.deleteConfirmation` cover
    /// (one full-screen cover per view).
    private enum ContainerDestructive {
        case prune
        case stopAll
        case kill(EnvironmentItem<ContainerSummary>)
        case remove(EnvironmentItem<ContainerSummary>)
        case bulkRemove([String])
    }

    private enum PowerAllAction {
        case startAll, startStopped, stopAll

        var successVerb: String {
            switch self {
            case .startAll, .startStopped: "Started"
            case .stopAll: "Stopped"
            }
        }
    }

    private var containers: [EnvironmentItem<ContainerSummary>] { list.items }

    private var createEnvironments: [ListEnvironment] {
        listEnvironments.filter { manager.permissions.has(Permission.Containers.create, in: $0.id) }
    }

    private func presentCreateContainer(in environmentID: EnvironmentID) {
        createEnvironmentID = environmentID
        showCreateContainer = true
    }

    /// The environments this list covers, known before the first load finishes.
    private var listEnvironments: [ListEnvironment] {
        allEnvironments ? list.environments : [ListEnvironment(id: environmentID, name: nil)]
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
        if environmentFilter != nil { count += 1 }
        if updateFilter != .all { count += 1 }
        if showHidden { count += 1 }
        if !labelFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { count += 1 }
        return count
    }

    /// Filters + sorts once and partitions in a single pass. Pure — reads the
    /// current inputs and returns the grouped sections without touching state.
    private func computeSections(pinned: Set<String>) -> [StableListSection<String, EnvironmentItem<ContainerSummary>>]
    {
        let query = debouncedSearchText
        let filtered = containers.filter { container in
            guard environmentFilter == nil || container.environmentID == environmentFilter else { return false }
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
        // displayName trims on every access; compute it once per item, not per comparison.
        .map { (key: (name: $0.displayName, sample: resourceSample(for: $0)), item: $0) }
        .sorted { sort.areInIncreasingOrder($0.key, $1.key) }
        .map(\.item)
        var pinnedItems: [EnvironmentItem<ContainerSummary>] = []
        var running: [EnvironmentItem<ContainerSummary>] = []
        var stopped: [EnvironmentItem<ContainerSummary>] = []
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
        let pinned = pinnedStore.pinnedIDs(kind: .container, in: containers)
        if pinned != pinnedIDs { pinnedIDs = pinned }
        sections = computeSections(pinned: pinned)
        pruneSelection(validIDs: Set(containers.map(\.id)))
    }

    private var mutationVersion: Int {
        allEnvironments
            ? mutationStore.version(kind: .containers, in: list.environments)
            : mutationStore.version(kind: .containers, envID: environmentID)
    }

    /// Per-section item counts — drives the List's implicit reflow animation so a
    /// programmatic insert/remove (start/stop/remove/prune) animates too.

    private var selectedContainers: [EnvironmentItem<ContainerSummary>] {
        containers.filter { selection.contains($0.id) }
    }

    private var selectedContainerIDs: [String] {
        selectedContainers.map(\.id)
    }

    /// Compose generation and updates run in one environment, so they need a
    /// selection from a single environment.
    private var selectionEnvironmentID: EnvironmentID? {
        let environments = Set(selectedContainers.map(\.environmentID))
        return environments.count == 1 ? environments.first : nil
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
            action.id != primary.id && selected.contains { action.applies(to: $0.value) }
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
        if !updatable.isEmpty, selectionEnvironmentID != nil {
            items.append(
                ActionButtonItem(
                    id: "bulk-update", title: "Update (\(updatable.count))", systemImage: "arrow.up.circle.fill",
                    tint: .blue
                ) {
                    startBulkUpdate(containers: updatable)
                })
        }
        if manager.serverCapabilities?.mode == .rbac, let selectionEnvironmentID,
            manager.permissions.has(Permission.Containers.read, in: selectionEnvironmentID)
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
            showSkeleton: list.isLoading && containers.isEmpty,
            animatesTransition: false
        ) {
            ArcaneLoadingView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } content: {
            if let error = list.errorMessage, containers.isEmpty {
                ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if containers.isEmpty {
                ContentUnavailableView {
                    Label("No Containers", systemImage: "cube.box")
                } description: {
                    Text(
                        allEnvironments
                            ? "No containers found in any environment." : "No containers found in this environment.")
                } actions: {
                    Button("Refresh") {
                        Task { await loadContainers() }
                    }
                }
            } else {
                List(selection: BulkListSelection.binding($selection, isSelecting: isSelecting)) {
                    EnvironmentLoadFailuresSection(failures: list.failedEnvironments) {
                        Task { await loadContainers() }
                    }
                    StableSectionedList(
                        sections,
                        preferredHeaderAccessorySectionID: "running",
                        headerAccessory: { _ in
                            ResourceCountLabel(
                                loadedCount: containers.count,
                                totalCount: list.totalItems,
                                hasMore: list.hasMore
                            )
                        }
                    ) { container in
                        containerLink(container)
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
                        if allEnvironments {
                            Divider()
                            AllEnvironmentsMaintenanceButtons(action: $pendingMaintenanceAction)
                        } else if canStartAll || canStopAll {
                            Divider()
                            if canStartAll {
                                Button {
                                    Task { await runPowerAll(.startAll) }
                                } label: {
                                    Label("Start All", systemImage: "play.fill")
                                }
                                Button {
                                    Task { await runPowerAll(.startStopped) }
                                } label: {
                                    Label("Start Stopped", systemImage: "play")
                                }
                            }
                            if canStopAll {
                                Button(role: .destructive) {
                                    pendingDestructive = .stopAll
                                } label: {
                                    DestructiveLabel(text: "Stop All", systemImage: "stop.fill")
                                }
                                .tint(.red)
                            }
                        }
                        Divider()
                        Button(role: .destructive) {
                            pendingDestructive = .prune
                        } label: {
                            DestructiveLabel(text: "Prune Stopped Containers")
                        }
                        .tint(.red)
                        .disabled(allEnvironments && AllEnvironmentsOperationStore.shared.isRunning)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .appAccentToolbarSymbol()
                    }
                    .accessibilityLabel("More options")
                }
                if !createEnvironments.isEmpty {
                    if #available(iOS 26, *) {
                        ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    }
                    AppToolbarItem(placement: .navigationBarTrailing) {
                        if allEnvironments {
                            EnvironmentActionButton(
                                title: "Create Container", systemImage: "plus", environments: createEnvironments
                            ) { environmentID in
                                presentCreateContainer(in: environmentID)
                            }
                            .appAccentToolbarSymbol()
                            .accessibilityLabel("Create container")
                        } else {
                            Button {
                                presentCreateContainer(in: environmentID)
                            } label: {
                                Image(systemName: "plus")
                                    .appAccentToolbarSymbol()
                            }
                            .accessibilityLabel("Create container")
                        }
                    }
                }
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
                    message: allEnvironments
                        ? ResourcePruneAction.containers.allEnvironmentsMessage
                        : "Remove all stopped containers. This cannot be undone.",
                    icon: "trash",
                    actions: [
                        DeleteConfirmationAction(title: "Prune") {
                            Task { await pruneContainers() }
                        }
                    ]
                )
            case .stopAll:
                return DeleteConfirmationConfig(
                    title: "Stop All Containers",
                    message: "Stop every running container in this environment.",
                    icon: "stop.fill",
                    actions: [
                        DeleteConfirmationAction(title: "Stop All") {
                            Task { await runPowerAll(.stopAll) }
                        }
                    ]
                )
            case .kill(let container):
                return DeleteConfirmationConfig(
                    title: "Kill Container",
                    message:
                        "Send SIGKILL to “\(container.displayName)”? It stops immediately without a graceful shutdown.",
                    icon: "bolt.fill",
                    actions: [
                        DeleteConfirmationAction(title: "Kill") {
                            Task { await killContainer(container) }
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
        .allEnvironmentsMaintenanceConfirmation(
            action: $pendingMaintenanceAction, environments: environmentsStore.enabledEnvironments
        )
        .sheet(isPresented: $showCreateContainer) {
            let createEnvironment = createEnvironmentID ?? environmentID
            ContainerConfigurationView(environmentID: createEnvironment) { id in
                routedDetails = nil
                routedContainer = EnvironmentItem(
                    ContainerSummary(id: id, image: "", imageId: "", state: "", status: ""),
                    in: listEnvironment(createEnvironment)
                )
            }
        }
        .sheet(isPresented: $showCompose) {
            ContainerComposeView(
                environmentID: selectionEnvironmentID ?? environmentID,
                containerIDs: selectedContainers.map(\.value.id)
            )
        }
        .sheet(isPresented: $showFilterSheet) {
            NavigationStack {
                Form {
                    Section {
                        Picker("Sort", selection: $sort) {
                            ForEach(ContainerListSort.allCases) { option in
                                Label(option.title, systemImage: option.systemImage).tag(option)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        Text("Sort")
                    } footer: {
                        Text("Live CPU and memory require Arcane 2.16 or later.")
                    }
                    EnvironmentFilterSection(environments: list.environments, selection: $environmentFilter)
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
            .presentationDetents([.medium, .large])
            .presentationContentInteraction(.resizes)
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $logsTarget) { container in
            LogsView(
                title: container.displayName,
                logStream: {
                    manager.client?.boundedContainerLogs(
                        envID: container.environmentID,
                        id: container.value.id,
                        timestamps: true
                    )
                }
            )
        }
        .fullScreenCover(item: $terminalTarget) { container in
            ContainerTerminalView(container: container.value, environmentID: container.environmentID)
        }
        // Reappearing (back from a detail) refreshes every loaded page in
        // place; the first appear loads page one.
        .task { await loadContainers(preservingLoadedRange: true) }
        .refreshable {
            async let samples: Void = refreshResourceSamples()
            await loadContainers()
            await samples
        }
        .debounce(searchText, for: .milliseconds(200), into: $debouncedSearchText)
        .debounce(labelFilter, for: .milliseconds(500), into: $debouncedLabelFilter)
        .navigationDestination(for: EnvironmentItem<ContainerSummary>.self) { container in
            ContainerDetailView(container: container.value, environmentID: container.environmentID)
        }
        .navigationDestination(item: $routedContainer) { container in
            ContainerDetailView(
                container: container.value, environmentID: container.environmentID, initialDetails: routedDetails
            )
        }
        .onChange(of: router.pendingRoute, initial: true) { _, _ in
            Task { await consumeContainerRoute() }
        }
        .onChange(of: mutationVersion) { _, _ in
            Task { await loadContainers(preservingLoadedRange: true) }
        }
        .onChange(of: list.revision) { rebuildSections() }
        .onChange(of: debouncedSearchText) {
            Task { await loadContainers() }
        }
        .onChange(of: environmentFilter) { rebuildSections() }
        .onChange(of: stateFilter) { rebuildSections() }
        .onChange(of: updateFilter) { rebuildSections() }
        .onChange(of: showHidden) {
            rebuildSections()
            Task { await loadContainers() }
        }
        .onChange(of: debouncedLabelFilter) {
            Task { await loadContainers() }
        }
        .onChange(of: sort) { oldValue, newValue in
            if oldValue.resourceSort == newValue.resourceSort {
                rebuildSections()
            } else {
                Task { await loadContainers(preservingLoadedRange: true) }
            }
        }
        .task(id: ResourcePollKey(environments: list.environments.map(\.id), isActive: scenePhase == .active)) {
            // Live usage while the list is on screen and the app is in front.
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await refreshResourceSamples()
                try? await Task.sleep(for: ContainerResourceSampleStore.refreshInterval)
            }
        }
        .onChange(of: resourceSamples.revision) {
            if sort.resourceSort != nil { rebuildSections() }
        }
        .onChange(of: pinnedStore.version) { rebuildSections() }
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

    private func containerLink(_ container: EnvironmentItem<ContainerSummary>) -> some View {
        let isPinned = pinnedIDs.contains(container.id)
        return NavigationLink(value: container) {
            ContainerRow(
                container: container.value,
                isPinned: isPinned,
                environmentName: container.environmentName,
                metrics: metrics(for: container)
            )
                .rowEnvironment(container)
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

    private func togglePinAfterSwipe(_ container: EnvironmentItem<ContainerSummary>) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            togglePin(container)
        }
    }

    private func togglePin(_ container: EnvironmentItem<ContainerSummary>) {
        HapticsManager.light()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pinnedStore.togglePin(container, kind: .container)
        }
    }

    @ViewBuilder
    private func containerMenuActions(for container: EnvironmentItem<ContainerSummary>) -> some View {
        if container.hasAvailableUpdate,
            manager.permissions.has(Permission.Containers.autoUpdate, in: container.environmentID)
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
            if manager.permissions.has("containers:kill", in: container.environmentID) {
                Button(role: .destructive) {
                    pendingDestructive = .kill(container)
                } label: {
                    DestructiveLabel(text: "Kill", systemImage: "bolt.fill")
                }
                .tint(.red)
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

    private func containerPreview(_ container: EnvironmentItem<ContainerSummary>) -> some View {
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
        if let environmentName = container.environmentName {
            details.append(.init(icon: "server.rack", label: "Environment", value: environmentName))
        }
        return RowPreviewCard(
            icon: "cube.box.fill",
            iconColor: container.isRunning ? .green : .secondary,
            iconUrl: container.value.themedIconUrl(for: colorScheme),
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
    private func containerSwipeActions(for container: EnvironmentItem<ContainerSummary>) -> some View {
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

    private func removeContainer(_ container: EnvironmentItem<ContainerSummary>) async {
        guard let client = manager.client else { return }
        do {
            try await client.containers.delete(envID: container.environmentID, id: container.value.id)
            list.update { $0.removeAll { $0.id == container.id } }
            rebuildSections()
            await invalidateContainerCaches(container.environmentID)
            mutationStore.markChanged(kind: .containers, envID: container.environmentID)
            showToast(.success("Container removed"))
            ReviewPrompter.shared.recordSuccess()
        } catch {
            showToast(.error("Couldn't remove container"))
        }
    }

    private func loadContainers(preservingLoadedRange: Bool = false) async {
        guard let client = manager.client else { return }
        let environments = await environmentsStore.listEnvironments(
            environmentID, allEnvironments: allEnvironments, manager: manager)
        await list.reload(
            environments, preservingLoadedRange: preservingLoadedRange, fetch: containersPage(client: client))
        rebuildSections()
    }

    private struct ResourcePollKey: Equatable {
        let environments: [EnvironmentID]
        let isActive: Bool
    }

    private func refreshResourceSamples() async {
        guard let client = manager.client else { return }
        await resourceSamples.refresh(client: client, environments: list.environments.map(\.id))
    }

    private func resourceSample(for container: EnvironmentItem<ContainerSummary>) -> ContainerResourceSample? {
        resourceSamples.sample(containerID: container.value.id, in: container.environmentID)
            ?? container.value.resourceSample
    }

    private func metrics(for container: EnvironmentItem<ContainerSummary>) -> ContainerRow.Metrics {
        guard container.isRunning, resourceSamples.supports(container.environmentID) else { return .hidden }
        if let sample = resourceSample(for: container) { return .sample(sample) }
        return resourceSamples.isPending(container.environmentID) ? .loading : .hidden
    }

    private func loadMore() async {
        guard let client = manager.client else { return }
        await list.loadMore(fetch: containersPage(client: client))
        rebuildSections()
    }

    private func containersPage(client: ArcaneClient) -> EnvironmentPagedList<ContainerSummary>.Fetch {
        let search = debouncedSearchText.isEmpty ? nil : debouncedSearchText
        let trimmedLabel = debouncedLabelFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let includeHidden: Bool? = showHidden ? true : nil
        let resourceSort = sort.resourceSort
        return { environmentID, start, limit in
            let response = try await client.containers.list(
                envID: environmentID,
                query: .init(
                    search: search, start: start, limit: limit,
                    sortBy: resourceSort?.rawValue, sortOrder: resourceSort == nil ? nil : .descending),
                includeHidden: includeHidden,
                label: trimmedLabel.isEmpty ? nil : trimmedLabel
            )
            return ResourcePage(items: response.data, pagination: response.pagination)
        }
    }

    private func listEnvironment(_ id: EnvironmentID) -> ListEnvironment {
        ListEnvironment(id: id, name: allEnvironments ? environmentsStore.displayName(for: id) ?? id.rawValue : nil)
    }

    private func startContainer(_ container: EnvironmentItem<ContainerSummary>) async {
        guard let client = manager.client else { return }
        do {
            try await client.containers.start(envID: container.environmentID, id: container.value.id)
            await invalidateContainerCaches(container.environmentID)
            mutationStore.markChanged(kind: .containers, envID: container.environmentID)
            showToast(.success("Container started"))
            ReviewPrompter.shared.recordSuccess()
        } catch {
            showToast(.error("Couldn't start container"))
        }
    }

    private func stopContainer(_ container: EnvironmentItem<ContainerSummary>) async {
        guard let client = manager.client else { return }
        do {
            try await client.containers.stop(envID: container.environmentID, id: container.value.id)
            await invalidateContainerCaches(container.environmentID)
            mutationStore.markChanged(kind: .containers, envID: container.environmentID)
            showToast(.success("Container stopped"))
            ReviewPrompter.shared.recordSuccess()
        } catch {
            showToast(.error("Couldn't stop container"))
        }
    }

    private func pruneContainers() async {
        if allEnvironments {
            await AllEnvironmentsOperationStore.shared.performPrune(
                .containers, environments: environmentsStore.enabledEnvironments, manager: manager)
            return
        }
        guard let client = manager.client else { return }
        do {
            try await ResourcePruneAction.containers.perform(client: client, environmentID: environmentID)
            await invalidateContainerCaches(environmentID)
            mutationStore.markChanged(kind: .containers, envID: environmentID)
            showToast(.success("Containers pruned"))
            ReviewPrompter.shared.recordSuccess()
        } catch {
            showToast(.error("Prune failed"))
        }
    }

    private var canStartAll: Bool {
        manager.permissions.has(Permission.Containers.start, in: environmentID)
    }

    private var canStopAll: Bool {
        manager.permissions.has(Permission.Containers.stop, in: environmentID)
    }

    private func runPowerAll(_ action: PowerAllAction) async {
        guard let client = manager.client else { return }
        do {
            let result: SystemContainerActionResult
            switch action {
            case .startAll: result = try await client.system.startAllContainers(envID: environmentID)
            case .startStopped: result = try await client.system.startAllStoppedContainers(envID: environmentID)
            case .stopAll: result = try await client.system.stopAllContainers(envID: environmentID)
            }
            await invalidateContainerCaches(environmentID)
            mutationStore.markChanged(kind: .containers, envID: environmentID)
            let changed = (action == .stopAll ? result.stopped : result.started)?.count ?? 0
            let failed = result.failed?.count ?? 0
            if failed > 0 {
                showToast(.error("\(failed) container\(failed == 1 ? "" : "s") failed"))
            } else if changed == 0 {
                showToast(.info("No containers to \(action == .stopAll ? "stop" : "start")"))
            } else {
                showToast(.success("\(action.successVerb) \(changed) container\(changed == 1 ? "" : "s")"))
                ReviewPrompter.shared.recordSuccess()
            }
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }

    private func killContainer(_ container: EnvironmentItem<ContainerSummary>) async {
        guard let client = manager.client else { return }
        do {
            try await client.containers.kill(envID: container.environmentID, id: container.value.id)
            await invalidateContainerCaches(container.environmentID)
            mutationStore.markChanged(kind: .containers, envID: container.environmentID)
            showToast(.success("Container killed"))
        } catch {
            showToast(.error("Couldn't kill container"))
        }
    }

    private func restartContainer(_ container: EnvironmentItem<ContainerSummary>) async {
        guard let client = manager.client else { return }
        do {
            try await client.containers.restart(envID: container.environmentID, id: container.value.id)
            await invalidateContainerCaches(container.environmentID)
            mutationStore.markChanged(kind: .containers, envID: container.environmentID)
            showToast(.success("Container restarted"))
            ReviewPrompter.shared.recordSuccess()
        } catch {
            showToast(.error("Couldn't restart container"))
        }
    }

    private func runBulkAction(_ action: ContainerBulkAction) async {
        guard let client = manager.client else { return }
        let targets = selectedContainers.filter { action.applies(to: $0.value) }
        guard !targets.isEmpty else {
            showToast(.info("No matching containers selected"))
            return
        }
        isBulkRunning = true
        bulkRunningActionID = action.id
        defer {
            isBulkRunning = false
            bulkRunningActionID = nil
        }
        let byID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
        let result = await BulkActionRunner.run(ids: targets.map(\.id)) { id in
            guard let container = byID[id] else { return }
            switch action {
            case .start:
                try await client.containers.start(envID: container.environmentID, id: container.value.id)
            case .stop:
                try await client.containers.stop(envID: container.environmentID, id: container.value.id)
            case .restart:
                try await client.containers.restart(envID: container.environmentID, id: container.value.id)
            }
        }
        await finishBulkOperation(
            result, total: targets.count, environments: targets.map(\.environmentID),
            successTitle: { count in
                "\(action.summaryVerb) \(count) container\(count == 1 ? "" : "s")"
            })
    }

    private func startBulkUpdate(containers: [EnvironmentItem<ContainerSummary>]) {
        guard let first = containers.first else { return }
        let targets = containers.map { DeploymentOperation.UpdateTarget(id: $0.value.id, name: $0.displayName) }
        let started = DeploymentActivityStore.shared.start(
            kind: .containerUpdate,
            envID: first.environmentID,
            targetID: targets[0].id,
            targetName: targets.count == 1 ? targets[0].name : "\(targets.count) containers",
            environmentName: first.environmentName ?? environmentName,
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
        let targets = containers.filter { ids.contains($0.id) }
        let byID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
        let result = await BulkActionRunner.run(ids: targets.map(\.id)) { id in
            guard let container = byID[id] else { return }
            try await client.containers.delete(envID: container.environmentID, id: container.value.id)
        }
        let failedIDs = Set(result.failed.map(\.id))
        let removedIDs = Set(targets.map(\.id).filter { !failedIDs.contains($0) })
        list.update { $0.removeAll { removedIDs.contains($0.id) } }
        await finishBulkOperation(
            result, total: targets.count, environments: targets.map(\.environmentID),
            successTitle: { count in
                "Removed \(count) container\(count == 1 ? "" : "s")"
            })
    }

    private func finishBulkOperation(
        _ result: BulkResult,
        total: Int,
        environments: [EnvironmentID],
        successTitle: (Int) -> String
    ) async {
        for environment in Set(environments) {
            await invalidateContainerCaches(environment)
            mutationStore.markChanged(kind: .containers, envID: environment)
        }
        rebuildSections()
        exitSelectionMode()
        if result.failed.isEmpty {
            showToast(.success(successTitle(result.succeeded)))
            ReviewPrompter.shared.recordSuccess()
        } else {
            showToast(.error("\(result.failed.count) of \(total) failed"))
        }
    }

    private func invalidateContainerCaches(_ environmentID: EnvironmentID) async {
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
    var metrics: Metrics = .hidden

    enum Metrics: Equatable {
        /// Stopped container, or a server without the shared stats collector.
        case hidden
        /// Waiting on the first sample; reserves the column invisibly so the row doesn't jump.
        case loading
        case sample(ContainerResourceSample)
    }

    private var resourceSample: ContainerResourceSample? {
        if case .sample(let sample) = metrics { return sample }
        return nil
    }

    var body: some View {
        // Each derived value parses the status string; evaluate them once per render.
        let health = self.health
        let statusText = self.statusText
        let updateState = ImageUpdateState(info: container.updateInfo)
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                CachedAsyncImage(url: container.themedIconUrl(for: colorScheme), size: 36, tiled: true) {
                    RowIcon(systemImage: "cube.box.fill", tint: .orange)
                }
                Circle()
                    .fill(container.isRunning ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 10, height: 10)
                    .offset(x: 2, y: 2)
                    .motionAwareAnimation(Motion.state, value: container.isRunning)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
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
                }
                UpdateStateBadge(state: updateState)
                EnvironmentLabel(name: environmentName)
            }

            Spacer(minLength: 8)

            // Running rows trade the play icon for live usage; the dot on the
            // icon already says it's running.
            if metrics == .hidden {
                StatusIcon(status: container.status, isLive: container.isRunning)
            } else {
                ContainerResourceMetrics(sample: resourceSample)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription(updateState: updateState))
    }

    private func accessibilityDescription(updateState: ImageUpdateState) -> String {
        var parts: [String] = [container.displayName]
        if isPinned { parts.append("pinned") }
        parts.append(container.isRunning ? "running" : "stopped")
        parts.append(container.image)
        parts.append(container.status)
        if let sample = resourceSample {
            parts.append(ContainerResourceMetrics.accessibilityDescription(sample))
        }
        parts.append(updateState.accessibilityDescription)
        if let environmentName { parts.append(environmentName) }
        return parts.joined(separator: ", ")
    }
}

/// Live CPU and memory from the server's shared stats sample, shown in the
/// trailing column of running container rows. Each ring fills against 100% CPU
/// or the memory limit. A nil sample keeps the column's space but stays invisible;
/// the first sample fades each line in and sweeps its ring up from empty.
struct ContainerResourceMetrics: View {
    let sample: ContainerResourceSample?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            metric(
                progress: (sample?.cpuPercent ?? 0) / 100,
                tint: .blue,
                value: sample.map(Self.cpuText),
                revealDelay: 0
            )
            metric(
                progress: (sample?.memoryPercent ?? 0) / 100,
                tint: .purple,
                value: sample.map(Self.memoryUsedText),
                revealDelay: Motion.stagger
            )
        }
        // Fixed width keeps the column aligned down the list as values change.
        .frame(minWidth: 76, alignment: .trailing)
    }

    private func metric(progress: Double, tint: Color, value: String?, revealDelay: TimeInterval) -> some View {
        let isRevealed = value != nil
        return HStack(spacing: 6) {
            Text(verbatim: value ?? "—")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .motionAwareAnimation(Motion.state, value: value)
            MetricRing(progress: progress, tint: tint, size: 14, lineWidth: 2.5)
                .motionAwareAnimation(Motion.gauge, value: progress)
        }
        .lineLimit(1)
        .fixedSize()
        .opacity(isRevealed ? 1 : 0)
        .offset(x: isRevealed ? 0 : 6)
        .motionAwareAnimation(Motion.entrance.delay(revealDelay), value: isRevealed)
    }

    static func cpuText(_ sample: ContainerResourceSample) -> String {
        String(format: "%.1f%%", sample.cpuPercent)
    }

    static func memoryUsedText(_ sample: ContainerResourceSample) -> String {
        Int64(clamping: sample.memoryUsageBytes).byteString
    }

    /// "of 1 GB"; nil when the server doesn't know the limit.
    static func memoryLimitText(_ sample: ContainerResourceSample) -> String? {
        guard sample.memoryLimitBytes > 0 else { return nil }
        return "of \(Int64(clamping: sample.memoryLimitBytes).byteString)"
    }

    static func accessibilityDescription(_ sample: ContainerResourceSample) -> String {
        var memory = memoryUsedText(sample)
        if let limit = memoryLimitText(sample) { memory += " \(limit)" }
        return "CPU \(cpuText(sample)), memory \(memory)"
    }
}

extension ContainersView {
    /// Resolves the destination independently of the paginated and filtered list.
    fileprivate func consumeContainerRoute() async {
        guard case .authenticated = manager.authState,
            case .container(let envID, let id)? = router.pendingRoute,
            allEnvironments || envID == environmentID.rawValue,
            let client = manager.client
        else { return }
        let routeEnvironmentID = EnvironmentID(rawValue: envID)
        routeGeneration += 1
        let generation = routeGeneration
        let routerGeneration = router.routeGeneration
        let session = manager.cacheSessionIdentity
        router.pendingRoute = nil
        do {
            let details = try await RemoteDataLimits.boundedContainerInspect(
                client: client,
                environmentID: routeEnvironmentID,
                containerID: id
            )
            try Task.checkCancellation()
            guard generation == routeGeneration,
                routerGeneration == router.routeGeneration,
                session == manager.cacheSessionIdentity,
                client.transport === manager.client?.transport,
                manager.acceptsEnvironmentContext(routeEnvironmentID)
            else { return }
            routedDetails = details
            routedContainer = EnvironmentItem(details.navigationSummary, in: listEnvironment(routeEnvironmentID))
        } catch {
            guard generation == routeGeneration,
                routerGeneration == router.routeGeneration,
                session == manager.cacheSessionIdentity,
                client.transport === manager.client?.transport,
                manager.acceptsEnvironmentContext(routeEnvironmentID)
            else { return }
            showToast(.error(friendlyErrorMessage(error)))
        }
    }
}
