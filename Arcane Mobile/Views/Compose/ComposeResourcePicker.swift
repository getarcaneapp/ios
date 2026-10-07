import SwiftUI
import Arcane

/// Selects an existing resource name without changing the Compose document.
struct ComposeResourcePicker: View {
    let kind: ComposeEntryKind
    @Binding var selection: String
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var names: [String] = []
    @State private var pagination = ProgressivePaginationState()
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loadedQuery: String?

    private var isVolume: Bool { kind == .mount }
    private var canList: Bool {
        (kind == .mount || kind == .network)
            && manager.permissions.has(isVolume ? Permission.Volumes.list : Permission.Networks.list,
                                       in: manager.activeEnvironmentID)
    }
    private var queryKey: String {
        "\(manager.cacheSessionIdentity)|\(manager.activeEnvironmentID)|\(canList)|\(search)"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("The selected resource will be declared external when you apply this entry.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !canList {
                    ContentUnavailableView("Listing Access Required", systemImage: "lock.fill",
                                           description: Text("You can close this picker and enter a name manually."))
                } else {
                    ForEach(names, id: \.self) { name in
                        Button {
                            guard loadedQuery == queryKey, canList else { return }
                            selection = name
                            dismiss()
                        } label: {
                            HStack {
                                Label(name, systemImage: isVolume ? "externaldrive" : "network")
                                    .foregroundStyle(.primary)
                                Spacer()
                                if name == selection { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    if isLoading {
                        ProgressView("Loading…").frame(maxWidth: .infinity)
                    } else if let errorMessage {
                        Section {
                            Label(errorMessage, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                            Button("Try Again") { Task { await load(reset: names.isEmpty) } }
                        }
                    } else if names.isEmpty {
                        ContentUnavailableView.search(text: search)
                    } else if pagination.hasMore {
                        Button("Load More") { Task { await load(reset: false) } }
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle(isVolume ? "Choose Volume" : "Choose Network")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search names")
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task(id: queryKey) {
                _ = pagination.reset()
                names = []
                isLoading = false
                errorMessage = nil
                loadedQuery = nil
                guard canList else { return }
                do { try await Task.sleep(for: ListUX.searchDebounce) }
                catch { return }
                await load(reset: true)
            }
        }
    }

    private func load(reset: Bool) async {
        guard canList, !isLoading, let client = manager.client else { return }
        let requestedQuery = queryKey
        let generation = reset ? pagination.reset() : pagination.generation
        let start = reset ? 0 : pagination.nextStart
        let environmentID = manager.activeEnvironmentID
        let query = SearchPaginationSort(search: search.isEmpty ? nil : search, start: start,
                                         limit: ListUX.pageSizeDefault, sortBy: "name", sortOrder: .ascending)
        isLoading = true
        errorMessage = nil
        defer { if pagination.accepts(generation) { isLoading = false } }
        do {
            if isVolume {
                let response = try await client.volumes.list(envID: environmentID, query: query)
                try Task.checkCancellation()
                guard requestedQuery == queryKey, pagination.accepts(generation) else { return }
                merge(response.data.map(\.name), reset: reset)
                pagination.receive(pagination: response.pagination, itemCount: response.data.count,
                                   requestedStart: start, requestedLimit: ListUX.pageSizeDefault, generation: generation)
            } else {
                let response = try await client.networks.list(envID: environmentID, query: query)
                try Task.checkCancellation()
                guard requestedQuery == queryKey, pagination.accepts(generation) else { return }
                merge(response.data.map(\.name), reset: reset)
                pagination.receive(pagination: response.pagination, itemCount: response.data.count,
                                   requestedStart: start, requestedLimit: ListUX.pageSizeDefault, generation: generation)
            }
            loadedQuery = requestedQuery
        } catch is CancellationError {
            return
        } catch {
            guard requestedQuery == queryKey, pagination.accepts(generation) else { return }
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func merge(_ incoming: [String], reset: Bool) {
        if reset { names = [] }
        var existing = Set(names)
        names.append(contentsOf: incoming.filter { existing.insert($0).inserted })
    }
}
