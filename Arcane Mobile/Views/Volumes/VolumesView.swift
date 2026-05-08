import SwiftUI
import Arcane

nonisolated private struct VolumeListEnvelope: Decodable, Sendable {
    let data: [VolumeInfo]?
}

struct VolumesView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let environmentID: EnvironmentID
    let environmentName: String

    @State private var volumes: [VolumeInfo] = []
    @State private var sizes: [String: Int64] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var showCreateSheet = false
    @State private var showPruneConfirm = false
    @State private var showFilterSheet = false
    @State private var scopeFilter = VolumeScopeFilter.all
    @State private var sortOrder = ListSortOrder.ascending

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
                    ForEach(filtered) { volume in
                        NavigationLink(destination: VolumeDetailView(volume: volume, environmentID: environmentID)) {
                            VolumeRow(volume: volume, size: sizes[volume.name])
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await deleteVolume(volume) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
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
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showCreateSheet = true } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showPruneConfirm = true } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .task { await loadVolumes() }
        .refreshable { await loadVolumes(refresh: true) }
        .sheet(isPresented: $showCreateSheet) {
            CreateVolumeView(environmentID: environmentID) {
                await invalidateVolumeCaches()
                await loadVolumes(refresh: true)
            }
        }
        .alert("Prune Unused Volumes", isPresented: $showPruneConfirm) {
            Button("Prune", role: .destructive) { Task { await pruneVolumes() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All unused volumes will be permanently deleted.")
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
    }

    private func loadVolumes(refresh: Bool = false) async {
        guard let client = manager.client, let cached = manager.cached else { return }
        if volumes.isEmpty { isLoading = true }
        errorMessage = nil
        defer { isLoading = false }
        let path = client.rest.environmentPath(environmentID, "volumes")
        do {
            // Bypass the SDK's strict OpenAPI decoder — Docker can send `null` for
            // labels/options on empty volumes, but the generated Volume type requires
            // a dictionary. We decode our tolerant VolumeInfo directly, then store
            // the post-decoded array in the response cache.
            let fetcher: @Sendable () async throws -> [VolumeInfo] = {
                let raw = try await client.transport.rawRequest(path, body: Optional<String>.none)
                let envelope = try JSONDecoder().decode(VolumeListEnvelope.self, from: raw)
                return envelope.data ?? []
            }
            if let result = try await cached.getCustom(
                path: path, as: [VolumeInfo].self, policy: .volumes,
                envID: environmentID, refresh: refresh,
                onFresh: { fresh in volumes = fresh },
                fetcher: fetcher
            ) {
                volumes = result
            }
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
        await loadSizes(refresh: refresh)
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


    private func deleteVolume(_ volume: VolumeInfo) async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "volumes/\(volume.name)")
            let _: DataResponse<String> = try await client.rest.delete(path)
            volumes.removeAll { $0.name == volume.name }
            await invalidateVolumeCaches()
        } catch {}
    }

    private func pruneVolumes() async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "volumes/prune")
            let _: DataResponse<String> = try await client.rest.post(path, body: String?.none)
            await invalidateVolumeCaches()
            await loadVolumes(refresh: true)
        } catch {}
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

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(volume.name)
                        .font(.headline)
                        .lineLimit(1)
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
    }
}

struct VolumeDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let volume: VolumeInfo
    let environmentID: EnvironmentID

    @State private var showDeleteConfirm = false
    @State private var sizeBytes: Int64? = nil
    @State private var loadingSize = false

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
            Button("Delete", role: .destructive) { /* handled by parent */ }
        }
        .task { await loadSize() }
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
}

struct CreateVolumeView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
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
            await onSuccess(); dismiss()
        } catch { errorMessage = friendlyErrorMessage(error) }
    }
}
