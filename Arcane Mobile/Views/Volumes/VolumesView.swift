import SwiftUI
import Arcane

struct VolumesView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let environmentID: EnvironmentID
    let environmentName: String

    @State private var volumes: [VolumeInfo] = []
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
                    ResourceSearchControls(
                        searchText: $searchText,
                        sortOrder: $sortOrder,
                        prompt: "Search volumes",
                        filterActive: activeFilterCount > 0
                    ) {
                        showFilterSheet = true
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)

                    ForEach(filtered) { volume in
                        NavigationLink(destination: VolumeDetailView(volume: volume, environmentID: environmentID)) {
                            VolumeRow(volume: volume)
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
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { Task { await loadVolumes() } } label: {
                    Image(systemName: "arrow.clockwise")
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
        .refreshable { await loadVolumes() }
        .sheet(isPresented: $showCreateSheet) {
            CreateVolumeView(environmentID: environmentID) {
                await loadVolumes()
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

    private func loadVolumes() async {
        guard let client = manager.client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let path = client.rest.environmentPath(environmentID, "volumes")
            volumes = try await client.rest.get(path)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteVolume(_ volume: VolumeInfo) async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "volumes/\(volume.name)")
            let _: DataResponse<String> = try await client.rest.delete(path)
            volumes.removeAll { $0.name == volume.name }
        } catch {}
    }

    private func pruneVolumes() async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "volumes/prune")
            let _: DataResponse<String> = try await client.rest.post(path, body: String?.none)
            await loadVolumes()
        } catch {}
    }
}

struct VolumeRow: View {
    let volume: VolumeInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.fill")
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 36, height: 36)
                .glassEffect(.regular, in: .circle)

            VStack(alignment: .leading, spacing: 3) {
                Text(volume.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(volume.driver)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("•")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(volume.scope)
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
            }

            let labels = volume.labels.additionalProperties
            if !labels.isEmpty {
                Section("Labels") {
                    ForEach(Array(labels.keys.sorted()), id: \.self) { key in
                        LabeledContent(key, value: labels[key] ?? "")
                    }
                }
            }

            let options = volume.options.additionalProperties
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
            let _: VolumeInfo = try await client.rest.post(path, body: body)
            await onSuccess(); dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
