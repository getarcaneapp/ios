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
    @State private var showPruneConfirm = false
    @State private var showFilterSheet = false
    @State private var stateFilter = ContainerStateFilter.all
    @State private var sortOrder = ListSortOrder.ascending
    @State private var sections: [StableListSection<String, ContainerSummary>] = []

    private enum ContainerStateFilter: String, CaseIterable {
        case all = "All", running = "Running", stopped = "Stopped"
    }

    private var activeFilterCount: Int { stateFilter != .all ? 1 : 0 }

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
            return matchesSearch && matchesState
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
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { sections = new }
        } else {
            sections = new
        }
    }

    private var mutationVersion: Int {
        mutationStore.version(kind: .containers, envID: environmentID)
    }

    var body: some View {
        Group {
            if isLoading && containers.isEmpty {
                SkeletonListLoadingView()
            } else if let error = errorMessage, containers.isEmpty {
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
                Button { showPruneConfirm = true } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Prune stopped containers")
            }
        }
        .alert("Prune Stopped Containers", isPresented: $showPruneConfirm) {
            Button("Prune", role: .destructive) { Task { await pruneContainers() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove all stopped containers. This cannot be undone.")
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
                .navigationTransition(.zoom(sourceID: container.id, in: heroTransition))
        }
        .onChange(of: mutationVersion) { _, _ in
            Task { await loadContainers(refresh: true) }
        }
        .onChange(of: debouncedSearchText) { rebuildSections() }
        .onChange(of: stateFilter) { rebuildSections(animated: true) }
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
                Task { await removeContainer(container) }
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
            HapticsManager.success()
            ReviewPrompter.shared.recordSuccess()
        } catch {
            HapticsManager.warning()
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
            HapticsManager.success()
            ReviewPrompter.shared.recordSuccess()
        } catch {
            HapticsManager.warning()
        }
    }

    private func stopContainer(_ container: ContainerSummary) async {
        guard let client = manager.client else { return }
        do {
            try await client.containers.stop(envID: environmentID, id: container.id)
            await invalidateContainerCaches()
            mutationStore.markChanged(kind: .containers, envID: environmentID)
            HapticsManager.success()
            ReviewPrompter.shared.recordSuccess()
        } catch {
            HapticsManager.warning()
        }
    }

    private func pruneContainers() async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "containers/prune")
            let _: DataResponse<String> = try await client.rest.post(path, body: String?.none)
            await invalidateContainerCaches()
            mutationStore.markChanged(kind: .containers, envID: environmentID)
            HapticsManager.success()
            ReviewPrompter.shared.recordSuccess()
        } catch {
            HapticsManager.warning()
        }
    }

    private func restartContainer(_ container: ContainerSummary) async {
        guard let client = manager.client else { return }
        do {
            try await client.containers.restart(envID: environmentID, id: container.id)
            await invalidateContainerCaches()
            mutationStore.markChanged(kind: .containers, envID: environmentID)
            HapticsManager.success()
            ReviewPrompter.shared.recordSuccess()
        } catch {
            HapticsManager.warning()
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
            .glassEffect(.regular, in: .capsule)

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
            .glassEffect(.regular, in: .circle)

            Button(action: onFilter) {
                Image(systemName: filterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .glassEffect(.regular, in: .circle)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

struct ContainerRow: View {
    let container: ContainerSummary
    var isPinned: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                CachedAsyncImage(url: container.iconUrl, size: 36) {
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
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(container.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .accessibilityHidden(true)
                    }
                }
            }

            Spacer()

            StatusBadge(status: container.status, isLive: container.isRunning)
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
