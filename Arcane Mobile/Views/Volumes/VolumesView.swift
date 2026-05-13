import SwiftUI
import Arcane

struct VolumesView: View {
    private static let pageSize = 50

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(PinnedItemsStore.self) private var pinnedStore
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    let environmentID: EnvironmentID
    let environmentName: String

    @State private var volumes: [VolumeInfo] = []
    @State private var sizes: [String: Int64] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var actionErrorMessage: String?
    @State private var searchText = ""
    @State private var showCreateSheet = false
    @State private var showPruneConfirm = false
    @State private var showFilterSheet = false
    @State private var scopeFilter = VolumeScopeFilter.all
    @State private var sortOrder = ListSortOrder.ascending
    @State private var currentPage = 1
    @State private var hasMore = false
    @State private var loadGeneration = 0

    private enum VolumeScopeFilter: String, CaseIterable {
        case all = "All", local = "Local", global = "Global"
    }

    private var activeFilterCount: Int { scopeFilter != .all ? 1 : 0 }

    private var filtered: [VolumeInfo] {
        volumes.filter { volume in
            let matchesSearch = searchText.isEmpty ||
                volume.name.localizedCaseInsensitiveContains(searchText) ||
                volume.driver.localizedCaseInsensitiveContains(searchText)
            let matchesScope = scopeFilter == .all
                || (scopeFilter == .local && volume.scope.lowercased() == "local")
                || (scopeFilter == .global && volume.scope.lowercased() != "local")
            return matchesSearch && matchesScope
        }
        .sorted {
            sortOrder.areInIncreasingOrder($0.name, $1.name)
        }
    }

    private var pinnedIDs: Set<String> {
        pinnedStore.pinnedIDs(kind: .volume, envID: environmentID)
    }

    private var listSections: [StableListSection<String, VolumeInfo>] {
        let pinned: Set<String> = pinnedIDs
        var pinnedItems: [VolumeInfo] = []
        var used: [VolumeInfo] = []
        var unused: [VolumeInfo] = []
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

    private var mutationVersion: Int {
        mutationStore.version(kind: .volumes, envID: environmentID)
    }

    var body: some View {
        Group {
            if isLoading && volumes.isEmpty {
                ProgressView("Loading volumes...").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage, volumes.isEmpty {
                ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if volumes.isEmpty {
                ContentUnavailableView("No Volumes", systemImage: "externaldrive", description: Text("No volumes found"))
            } else {
                List {
                    StableSectionedList(listSections) { volume in
                        volumeLink(volume)
                    }

                    if hasMore {
                        Button("Load More") {
                            Task { await loadMore() }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Volumes")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search volumes")
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
                Button { showCreateSheet = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create volume")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showPruneConfirm = true } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Prune unused volumes")
            }
        }
        .task { await loadVolumes(reset: true) }
        .refreshable { await loadVolumes(reset: true, refresh: true) }
        .sheet(isPresented: $showCreateSheet) {
            CreateVolumeView(environmentID: environmentID) {}
        }
        .alert("Prune Unused Volumes", isPresented: $showPruneConfirm) {
            Button("Prune", role: .destructive) { Task { await pruneVolumes() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All unused volumes will be permanently deleted.")
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
                            ForEach(VolumeScopeFilter.allCases, id: \.self) { f in
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
        .onChange(of: mutationVersion) { _, _ in
            Task { await loadVolumes(reset: true, refresh: true) }
        }
    }

    private func volumeLink(_ volume: VolumeInfo) -> some View {
        let isPinned = pinnedIDs.contains(volume.id)
        return NavigationLink(destination: VolumeDetailView(volume: volume, environmentID: environmentID)) {
            VolumeRow(volume: volume, size: sizes[volume.name], isPinned: isPinned)
        }
        .contextMenu {
            Button {
                togglePin(volume)
            } label: {
                Label(isPinned ? "Unpin" : "Pin",
                      systemImage: isPinned ? "pin.slash.fill" : "pin.fill")
            }
            Button(role: .destructive) {
                Task { await deleteVolume(volume) }
            } label: {
                DestructiveLabel(text: "Delete")
            }
            .tint(.red)
        } preview: {
            volumePreview(volume)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                togglePinAfterSwipe(volume)
            } label: {
                Label(isPinned ? "Unpin" : "Pin",
                      systemImage: isPinned ? "pin.slash.fill" : "pin.fill")
            }
            .tint(.yellow)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await deleteVolume(volume) }
            } label: {
                DestructiveLabel(text: "Delete")
            }
        }
    }

    private func togglePinAfterSwipe(_ volume: VolumeInfo) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            togglePin(volume)
        }
    }

    private func togglePin(_ volume: VolumeInfo) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pinnedStore.togglePin(volume.id, kind: .volume, envID: environmentID)
        }
    }

    private func volumePreview(_ volume: VolumeInfo) -> some View {
        var badges: [RowPreviewCard.PreviewBadge] = []
        if let inUse = volume.inUse {
            badges.append(.init(text: inUse ? "In Use" : "Unused",
                                color: inUse ? .green : .secondary))
        }
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
            let response: VolumeListPage?
            if reset, let cached = manager.cached {
                let path = client.rest.environmentPath(environmentID, "volumes")
                let cachePath = "\(path)?start=0&limit=\(Self.pageSize)"
                let fetcher: @Sendable () async throws -> VolumeListPage = {
                    try await client.listVolumesPage(
                        envID: environmentID,
                        start: 0,
                        limit: Self.pageSize
                    )
                }
                response = try await cached.getCustom(
                    path: cachePath,
                    as: VolumeListPage.self,
                    policy: .volumes,
                    envID: environmentID,
                    refresh: refresh,
                    onFresh: { fresh in applyVolumesPage(fresh, reset: true, generation: generation) },
                    fetcher: fetcher
                )
            } else {
                response = try await client.listVolumesPage(
                    envID: environmentID,
                    start: start,
                    limit: Self.pageSize
                )
            }
            guard let response else {
                guard loadGeneration == generation else { return }
                if reset {
                    volumes = []
                    currentPage = 1
                    hasMore = false
                }
                return
            }
            applyVolumesPage(response, reset: reset, generation: generation)
        } catch {
            guard loadGeneration == generation else { return }
            errorMessage = friendlyErrorMessage(error)
        }
        if reset || sizes.isEmpty {
            await loadSizes(refresh: refresh)
        }
    }

    private func applyVolumesPage(_ response: VolumeListPage, reset: Bool, generation: Int) {
        guard loadGeneration == generation else { return }
        if reset {
            volumes = response.data
        } else {
            let existing = Set(volumes.map(\.id))
            volumes.append(contentsOf: response.data.filter { !existing.contains($0.id) })
        }
        currentPage = max(Int(response.pagination.currentPage), 1)
        hasMore = response.pagination.currentPage < response.pagination.totalPages
    }

    private func loadSizes(refresh: Bool = false) async {
        guard let client = manager.client, let cached = manager.cached else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "volumes/sizes")
            if let entries: [VolumeSizeInfo] = try await cached.get(
                path, as: [VolumeSizeInfo].self, policy: .volumes,
                envID: environmentID, refresh: refresh,
                onFresh: { fresh in
                    sizes = Dictionary(uniqueKeysWithValues: fresh.map { ($0.name, $0.size) })
                }
            ) {
                sizes = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.size) })
            }
        } catch {
            // Slow / unsupported on some hosts — leave sizes blank silently.
        }
    }

    private func loadMore() async {
        guard hasMore else { return }
        await loadVolumes(reset: false)
    }


    private func deleteVolume(_ volume: VolumeInfo) async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "volumes/\(volume.name)")
            let _: DataResponse<String> = try await client.rest.delete(path)
            withAnimation {
                volumes.removeAll { $0.name == volume.name }
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
    let volume: VolumeInfo
    var size: Int64? = nil
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
                .foregroundStyle(.orange)
                .frame(width: 36, height: 36)
                .glassEffect(.regular, in: .circle)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(volume.name)
                        .font(.headline)
                        .lineLimit(1)
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .accessibilityHidden(true)
                    }
                    if volume.inUse == true {
                        UsageBadge(text: "In use", color: .green)
                    } else if volume.inUse == false {
                        UsageBadge(text: "Unused", color: .secondary)
                    }
                }
                if !subtitleParts.isEmpty {
                    Text(subtitleParts.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        if volume.inUse == true { parts.append("in use") }
        else if volume.inUse == false { parts.append("unused") }
        if !subtitleParts.isEmpty { parts.append(subtitleParts.joined(separator: ", ")) }
        return parts.joined(separator: ", ")
    }
}

struct VolumeDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let volume: VolumeInfo
    let environmentID: EnvironmentID

    @State private var showDeleteConfirm = false
    @State private var sizeBytes: Int64? = nil
    @State private var loadingSize = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "externaldrive.fill")
                        .font(.title)
                        .foregroundStyle(.orange)
                        .frame(width: 56, height: 56)
                        .glassEffect(.regular, in: .circle)
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

            let labels = volume.labelsDictionary
            if !labels.isEmpty {
                Section("Labels") {
                    ForEach(Array(labels.keys.sorted()), id: \.self) { key in
                        LabeledContent(key, value: labels[key] ?? "")
                    }
                }
            }

            let options = volume.optionsDictionary
            if !options.isEmpty {
                Section("Options") {
                    ForEach(Array(options.keys.sorted()), id: \.self) { key in
                        LabeledContent(key, value: options[key] ?? "")
                    }
                }
            }

        }
        .listStyle(.insetGrouped)
        .navigationTitle(volume.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
            }
        }
        .confirmationDialog("Delete Volume", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await deleteVolume() }
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
            let path = client.rest.environmentPath(environmentID, "volumes/\(volume.name)")
            let _: DataResponse<String> = try await client.rest.delete(path)
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
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let environmentID: EnvironmentID
    let onSuccess: () async -> Void

    @State private var name = ""
    @State private var driver = "local"
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Volume Details") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Driver", text: $driver)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
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
                        .disabled(name.isEmpty || isLoading)
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
