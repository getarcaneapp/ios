import SwiftUI
import Arcane

struct ContainersView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(PinnedItemsStore.self) private var pinnedStore
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var heroTransition
    let environmentID: EnvironmentID
    let environmentName: String

    @State private var containers: [ContainerSummary] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var pendingDestructive: ContainerDestructive?
    @State private var showFilterSheet = false
    @State private var stateFilter = ContainerStateFilter.all
    @State private var updateFilter = ResourceUpdateFilter.all
    @State private var sortOrder = ListSortOrder.ascending
    @State private var sections: [StableListSection<String, ContainerSummary>] = []
    @State private var logsTarget: ContainerSummary?
    @State private var terminalTarget: ContainerSummary?
    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var isBulkRunning = false
    @State private var bulkRunningActionID: String?

    private enum ContainerStateFilter: String, CaseIterable {
        case all = "All", running = "Running", stopped = "Stopped"
    }

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
            let matchesSearch = query.isEmpty ||
                container.names.contains(where: { $0.localizedCaseInsensitiveContains(query) }) ||
                container.image.localizedCaseInsensitiveContains(query)
            let matchesState = stateFilter == .all
                || (stateFilter == .running && container.isRunning)
                || (stateFilter == .stopped && !container.isRunning)
            let matchesUpdate = updateFilter.matches(hasUpdate: container.hasAvailableUpdate)
            return matchesSearch && matchesState && matchesUpdate
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
            .init(id: "stopped", title: "Stopped", items: stopped)
        ]
    }

    /// Refresh the cached `sections`. Called only when an input that affects
    /// grouping actually changes (search settle, sort, filter, pins, or the
    /// source list) — never on every body evaluation.
    private func rebuildSections(animated: Bool = false) {
        let new = computeSections()
        if animated {
            withAnimation(Motion.reduced(Motion.reflow, reduceMotion: reduceMotion)) { sections = new }
        } else {
            sections = new
        }
        pruneSelection(validIDs: Set(containers.map(\.id)))
    }

    private var mutationVersion: Int {
        mutationStore.version(kind: .containers, envID: environmentID)
    }

    /// Per-section item counts — drives the List's implicit reflow animation so a
    /// programmatic insert/remove (start/stop/remove/prune) animates too.
    private var sectionCounts: [Int] { sections.map(\.items.count) }

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
        return [
            ActionButtonItem(
                id: "bulk-delete",
                title: "Remove",
                systemImage: "trash",
                tint: .red
            ) {
                pendingDestructive = .bulkRemove(selectedContainerIDs)
            }
        ]
    }

    var body: some View {
        LoadingCrossfade(showSkeleton: isLoading && containers.isEmpty) {
            SkeletonListLoadingView()
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
                        Task { await loadContainers(refresh: true) }
                    }
                }
            } else {
                List(selection: $selection) {
                    StableSectionedList(sections) { container in
                        containerLink(container)
                    }
                }
                .listStyle(.insetGrouped)
                .environment(\.editMode, .constant(isSelecting ? EditMode.active : EditMode.inactive))
                .motionAwareAnimation(Motion.reflow, value: sectionCounts)
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
                    Button(role: .destructive) { pendingDestructive = .prune } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .accessibilityLabel("Prune stopped containers")
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
                    actions: [DeleteConfirmationAction(title: "Prune") {
                        Task { await pruneContainers() }
                    }]
                )
            case .remove(let container):
                return DeleteConfirmationConfig(
                    title: "Remove Container",
                    message: "Remove “\(container.displayName)”? This permanently deletes the container.",
                    icon: "trash",
                    actions: [DeleteConfirmationAction(title: "Remove") {
                        Task { await removeContainer(container) }
                    }]
                )
            case .bulkRemove(let ids):
                return DeleteConfirmationConfig(
                    title: "Remove Containers",
                    message: "Remove \(ids.count) selected container" +
                        "\(ids.count == 1 ? "" : "s")? This cannot be undone.",
                    icon: "trash",
                    actions: [DeleteConfirmationAction(title: "Remove") {
                        Task { await bulkRemoveContainers(ids: ids) }
                    }]
                )
            }
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
        .sheet(item: $logsTarget) { container in
            LogsView(
                title: container.displayName,
                logStream: { timestamps in
                    manager.client?.containers.logs(
                        envID: environmentID,
                        id: container.id,
                        timestamps: timestamps
                    )
                }
            )
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $terminalTarget) { container in
            ContainerTerminalView(container: container, environmentID: environmentID)
        }
        .task { await loadContainers() }
        .refreshable { await loadContainers(refresh: true) }
        .debounce(searchText, for: .milliseconds(200), into: $debouncedSearchText)
        .navigationDestination(for: ContainerSummary.self) { container in
            ContainerDetailView(container: container, environmentID: environmentID)
                .pageEntranceFromTop()
        }
        .onChange(of: mutationVersion) { _, _ in
            Task { await loadContainers(refresh: true) }
        }
        .onChange(of: debouncedSearchText) { rebuildSections() }
        .onChange(of: stateFilter) { rebuildSections(animated: true) }
        .onChange(of: updateFilter) { rebuildSections(animated: true) }
        .onChange(of: sortOrder) { rebuildSections(animated: true) }
        .onChange(of: pinnedIDs) { rebuildSections() }
        .morphingActions(
            primary: bulkPrimaryItem,
            inline: bulkInlineItems,
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
        .matchedTransitionSource(id: container.id, in: heroTransition)
        .contextMenu {
            if !isSelecting {
                Button {
                    togglePin(container)
                } label: {
                    Label(isPinned ? "Unpin" : "Pin",
                          systemImage: isPinned ? "pin.slash.fill" : "pin.fill")
                }
                containerMenuActions(for: container)
            }
        } preview: {
            if !isSelecting {
                containerPreview(container)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if !isSelecting {
                Button {
                    togglePinAfterSwipe(container)
                } label: {
                    Label(isPinned ? "Unpin" : "Pin",
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
                Label("Stop", systemImage: "stop.fill")
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
            .init(icon: "info.circle", label: "Status", value: container.status)
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
            title: container.displayName,
            badges: [
                .init(text: container.isRunning ? "Running" : "Stopped",
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

    private func loadContainers(refresh: Bool = false) async {
        guard let client = manager.client, let cached = manager.cached else { return }
        if containers.isEmpty { isLoading = true }
        errorMessage = nil
        defer { isLoading = false }
        do {
            let path = client.rest.environmentPath(environmentID, "containers")
            if let result: [ContainerSummary] = try await cached.getList(
                path, elementType: ContainerSummary.self, policy: .containersList,
                envID: environmentID, refresh: refresh,
                onFresh: { fresh in containers = fresh; rebuildSections() }
            ) {
                containers = result
                rebuildSections()
            }
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
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
        await finishBulkOperation(result, total: ids.count, successTitle: { count in
            "\(action.summaryVerb) \(count) container\(count == 1 ? "" : "s")"
        })
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
        await finishBulkOperation(result, total: ids.count, successTitle: { count in
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
        rebuildSections(animated: true)
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
        await cached.invalidate(envID: environmentID, paths: [
            client.rest.environmentPath(environmentID, "containers"),
            client.rest.environmentPath(environmentID, "containers/*")
        ])
    }
}

struct ResourceSearchControls: View {
    @Binding var searchText: String
    @Binding var sortOrder: ListSortOrder
    let prompt: String
    let filterActive: Bool
    let onFilter: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(prompt, text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .glassEffectCompat(in: .capsule)

            Menu {
                Picker("Sort", selection: $sortOrder) {
                    ForEach(ListSortOrder.allCases) { order in
                        Label(order.title, systemImage: order.systemImage).tag(order)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .glassEffectCompat(in: .circle)

            Button(action: onFilter) {
                Image(
                    systemName: filterActive
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle"
                )
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .glassEffectCompat(in: .circle)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
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

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                CachedAsyncImage(url: container.themedIconUrl(for: colorScheme), size: 36) {
                    Image(systemName: "cube.box.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.accentColor, in: .circle)
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
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .accessibilityHidden(true)
                    }
                }
                if !statusText.isEmpty || health != nil {
                    HStack(spacing: 5) {
                        if !statusText.isEmpty {
                            Text(statusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let health {
                            Image(systemName: health.icon)
                                .font(.caption)
                                .foregroundStyle(health.color)
                                .accessibilityLabel(health.label)
                        }
                    }
                }
            }

            Spacer()

            StatusIcon(status: container.status, isLive: container.isRunning)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var parts: [String] = [container.displayName]
        if isPinned { parts.append("pinned") }
        parts.append(container.isRunning ? "running" : "stopped")
        parts.append(container.image)
        parts.append(container.status)
        return parts.joined(separator: ", ")
    }
}
