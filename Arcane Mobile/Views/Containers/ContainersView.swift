import SwiftUI
import Arcane

struct ContainersView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let environmentID: EnvironmentID
    let environmentName: String

    @State private var containers: [ContainerInfo] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var showPruneConfirm = false
    @State private var showFilterSheet = false
    @State private var stateFilter = ContainerStateFilter.all
    @State private var sortOrder = ListSortOrder.ascending

    private enum ContainerStateFilter: String, CaseIterable {
        case all = "All", running = "Running", stopped = "Stopped"
    }

    private var activeFilterCount: Int { stateFilter != .all ? 1 : 0 }

    private var filtered: [ContainerInfo] {
        containers.filter { c in
            let matchesSearch = searchText.isEmpty ||
                (c.names?.contains { $0.localizedCaseInsensitiveContains(searchText) } ?? false) ||
                c.image.localizedCaseInsensitiveContains(searchText)
            let matchesState = stateFilter == .all
                || (stateFilter == .running && c.isRunning)
                || (stateFilter == .stopped && !c.isRunning)
            return matchesSearch && matchesState
        }
        .sorted {
            sortOrder.areInIncreasingOrder($0.displayName, $1.displayName)
        }
    }

    private var runningContainers: [ContainerInfo] {
        filtered.filter(\.isRunning)
    }

    private var stoppedContainers: [ContainerInfo] {
        filtered.filter { !$0.isRunning }
    }

    var body: some View {
        Group {
            if isLoading && containers.isEmpty {
                ProgressView("Loading containers...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage, containers.isEmpty {
                ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if containers.isEmpty {
                ContentUnavailableView("No Containers", systemImage: "cube.box", description: Text("No containers found"))
            } else {
                List {
                    if !runningContainers.isEmpty {
                        Section("Running") {
                            ForEach(runningContainers) { container in
                                containerLink(container)
                            }
                        }
                    }

                    if !stoppedContainers.isEmpty {
                        Section("Stopped") {
                            ForEach(stoppedContainers) { container in
                                containerLink(container)
                            }
                        }
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
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showPruneConfirm = true } label: {
                    Image(systemName: "trash")
                }
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
    }

    private func containerLink(_ container: ContainerInfo) -> some View {
        NavigationLink(destination: ContainerDetailView(container: container, environmentID: environmentID)) {
            ContainerRow(container: container)
        }
        .contextMenu {
            containerMenuActions(for: container)
        } preview: {
            containerPreview(container)
        }
        .swipeActions(edge: .trailing) {
            containerSwipeActions(for: container)
        }
    }

    @ViewBuilder
    private func containerMenuActions(for container: ContainerInfo) -> some View {
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

    private func containerPreview(_ container: ContainerInfo) -> some View {
        var details: [RowPreviewCard.PreviewDetail] = [
            .init(icon: "photo", label: "Image", value: container.image),
            .init(icon: "info.circle", label: "Status", value: container.status)
        ]
        if let firstName = container.names?.first {
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
    private func containerSwipeActions(for container: ContainerInfo) -> some View {
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

    private func removeContainer(_ container: ContainerInfo) async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "containers/\(container.id)")
            let _: DataResponse<String> = try await client.rest.delete(path)
            containers.removeAll { $0.id == container.id }
            await invalidateContainerCaches()
        } catch {}
    }

    private func loadContainers(refresh: Bool = false) async {
        guard let client = manager.client, let cached = manager.cached else { return }
        if containers.isEmpty { isLoading = true }
        errorMessage = nil
        defer { isLoading = false }
        do {
            let path = client.rest.environmentPath(environmentID, "containers")
            if let result: [ContainerInfo] = try await cached.getList(
                path, elementType: ContainerInfo.self, policy: .containersList,
                envID: environmentID, refresh: refresh,
                onFresh: { fresh in containers = fresh }
            ) {
                containers = result
            }
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func startContainer(_ container: ContainerInfo) async {
        guard let client = manager.client else { return }
        do {
            try await client.containers.start(envID: environmentID, id: container.id)
            await invalidateContainerCaches()
            await loadContainers(refresh: true)
        } catch {}
    }

    private func stopContainer(_ container: ContainerInfo) async {
        guard let client = manager.client else { return }
        do {
            try await client.containers.stop(envID: environmentID, id: container.id)
            await invalidateContainerCaches()
            await loadContainers(refresh: true)
        } catch {}
    }

    private func pruneContainers() async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "containers/prune")
            let _: DataResponse<String> = try await client.rest.post(path, body: String?.none)
            await invalidateContainerCaches()
            await loadContainers(refresh: true)
        } catch {}
    }

    private func restartContainer(_ container: ContainerInfo) async {
        guard let client = manager.client else { return }
        do {
            try await client.containers.restart(envID: environmentID, id: container.id)
            await invalidateContainerCaches()
            await loadContainers(refresh: true)
        } catch {}
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
    let container: ContainerInfo

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                CachedAsyncImage(url: container.iconUrl, size: 36) {
                    Image(systemName: "cube.box.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 36, height: 36)
                        .glassEffect(.regular, in: .circle)
                }
                Circle()
                    .fill(container.isRunning ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 10, height: 10)
                    .offset(x: 2, y: 2)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(container.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(container.image)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(container.status)
                .font(.caption)
                .foregroundStyle(container.isRunning ? .green : .secondary)
        }
        .padding(.vertical, 2)
    }
}
