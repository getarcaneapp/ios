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

    private enum ContainerStateFilter: String, CaseIterable {
        case all = "All", running = "Running", stopped = "Stopped"
    }

    /// Prune and per-container remove share one `.deleteConfirmation` cover
    /// (one full-screen cover per view).
    private enum ContainerDestructive {
        case prune
        case remove(ContainerSummary)
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
        let filtered = containers.filter { c in
            let matchesSearch = query.isEmpty ||
                c.names.contains(where: { $0.localizedCaseInsensitiveContains(query) }) ||
                c.image.localizedCaseInsensitiveContains(query)
            let matchesState = stateFilter == .all
                || (stateFilter == .running && c.isRunning)
                || (stateFilter == .stopped && !c.isRunning)
            let matchesUpdate = updateFilter.matches(hasUpdate: c.hasAvailableUpdate)
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
    }

    private var mutationVersion: Int {
        mutationStore.version(kind: .containers, envID: environmentID)
    }

    /// Per-section item counts — drives the List's implicit reflow animation so a
    /// programmatic insert/remove (start/stop/remove/prune) animates too.
    private var sectionCounts: [Int] { sections.map(\.items.count) }

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
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    StableSectionedList(sections) { container in
                        containerLink(container)
                    }
                }
                .listStyle(.insetGrouped)
                .motionAwareAnimation(Motion.reflow, value: sectionCounts)
            }
        }
        .navigationTitle("Containers")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search containers")
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
                Button { pendingDestructive = .prune } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Prune stopped containers")
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
            }
        }
        .sheet(isPresented: $showFilterSheet) {
            NavigationStack {
                Form {
                    Section("State") {
                        Picker("State", selection: $stateFilter) {
                            ForEach(ContainerStateFilter.allCases, id: \.self) { f in
                                Text(f.rawValue).tag(f)
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
    }

    private func containerLink(_ container: ContainerSummary) -> some View {
        let isPinned = pinnedIDs.contains(container.id)
        return NavigationLink(value: container) {
            ContainerRow(container: container, isPinned: isPinned)
        }
        .matchedTransitionSource(id: container.id, in: heroTransition)
        .contextMenu {
            Button {
                togglePin(container)
            } label: {
                Label(isPinned ? "Unpin" : "Pin",
                      systemImage: isPinned ? "pin.slash.fill" : "pin.fill")
            }
            containerMenuActions(for: container)
        } preview: {
            containerPreview(container)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                togglePinAfterSwipe(container)
            } label: {
                Label(isPinned ? "Unpin" : "Pin",
                      systemImage: isPinned ? "pin.slash.fill" : "pin.fill")
            }
            .tint(.yellow)
        }
        .swipeActions(edge: .trailing) {
            containerSwipeActions(for: container)
        }
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
        if container.isRunning {
            Button {
                Task { await stopContainer(container) }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
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
            let path = client.rest.environmentPath(environmentID, "containers/\(container.id)")
            let _: DataResponse<String> = try await client.rest.delete(path)
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
                Image(systemName: filterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
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
        let s = container.status.lowercased()
        if s.contains("unhealthy") { return ("heart.slash.fill", .red, "Unhealthy") }
        if s.contains("health: starting") { return ("heart.fill", .yellow, "Health starting") }
        if s.contains("(healthy)") { return ("heart.fill", .green, "Healthy") }
        return nil
    }

    // The status string with the health parenthetical stripped, leaving the
    // uptime/downtime (e.g. "Up 3 hours", "Exited (0) 2 hours ago").
    private var statusText: String {
        var s = container.status
        for token in ["(healthy)", "(unhealthy)", "(health: starting)"] {
            s = s.replacingOccurrences(of: token, with: "", options: [.caseInsensitive])
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                CachedAsyncImage(url: container.themedIconUrl(for: colorScheme), size: 36) {
                    if #available(iOS 26, *) {
                        Image(systemName: "cube.box.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .glassEffect(.regular.tint(Color.accentColor), in: .circle)
                    } else {
                        Image(systemName: "cube.box.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.accentColor, in: .circle)
                    }
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
