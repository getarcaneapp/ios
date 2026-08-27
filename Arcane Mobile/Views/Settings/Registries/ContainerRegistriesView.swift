import SwiftUI
import Arcane

struct ContainerRegistriesView: View {
    private static let pageSize = 50

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var registries: [ContainerRegistry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showCreateRegistrySheet = false
    @State private var editingRegistry: ContainerRegistry?
    @State private var actionErrorMessage: String?
    @State private var pendingDeleteRegistry: ContainerRegistry?
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var pagination = ProgressivePaginationState()
    @State private var isLoadingMore = false
    @State private var loadMoreError: String?

    var body: some View {
        Group {
            if manager.currentUser?.isAdmin != true {
                ContentUnavailableView("Admin Required", systemImage: "lock.fill", description: Text("Only administrators can manage container registries."))
            } else if isLoading && registries.isEmpty {
                ProgressView("Loading registries...").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, registries.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't Load Registries", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { Task { await loadRegistries(refresh: true) } }
                }
            } else if registries.isEmpty {
                ContentUnavailableView {
                    Label("No Container Registries", systemImage: "shippingbox")
                } description: {
                    Text("Add a registry to pull private images and check for updates behind authentication.")
                } actions: {
                    Button("Add Registry") { showCreateRegistrySheet = true }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ResourceCountSectionHeader(
                            "Container Registries",
                            loadedCount: registries.count,
                            totalCount: pagination.totalItems,
                            hasMore: pagination.hasMore
                        )

                        ForEach(registries) { registry in
                            PressableRegistryRow(
                                registry: registry,
                                onEdit: { editingRegistry = registry },
                                onDelete: { pendingDeleteRegistry = registry }
                            )
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .dashboardCardBackground(cornerRadius: Radius.standard)
                        }

                        if pagination.hasMore {
                            if loadMoreError != nil {
                                Button("Retry loading more") {
                                    Task { await loadMore() }
                                }
                                .frame(maxWidth: .infinity)
                            } else {
                                SkeletonListRow()
                                    .skeletonShimmer()
                                    .onAppear {
                                        Task { await loadMore() }
                                    }
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 16)
                }
                .softTopScrollEdgeEffectCompat()
                .background(Color(uiColor: .systemGroupedBackground))
            }
        }
        .navigationTitle("Container Registries")
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search registries"
        )
        .debounce(searchText, for: .milliseconds(200), into: $debouncedSearchText)
        .onChange(of: debouncedSearchText) {
            Task { await loadRegistries(refresh: true) }
        }
        .deleteConfirmation(
            item: $pendingDeleteRegistry,
            title: { _ in "Delete Registry" },
            message: { _ in "This removes the container registry and its saved credentials." },
            icon: "trash",
            confirmTitle: "Delete"
        ) { registry in
            Task { await deleteRegistry(registry) }
        }
        .toolbar {
            if manager.currentUser?.isAdmin == true {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showCreateRegistrySheet = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add Registry")
                }
            }
        }
        .task {
            guard manager.currentUser?.isAdmin == true else { return }
            await loadRegistries()
        }
        .refreshable {
            guard manager.currentUser?.isAdmin == true else { return }
            await loadRegistries(refresh: true)
        }
        .sheet(isPresented: $showCreateRegistrySheet) {
            RegistryFormView(registry: nil) {
                if let cached = manager.cached {
                    await cached.invalidateGlobal(paths: ["container-registries", "container-registries/*"])
                }
                await loadRegistries(refresh: true)
            }
        }
        .sheet(item: $editingRegistry) { registry in
            RegistryFormView(registry: registry) {
                if let cached = manager.cached {
                    await cached.invalidateGlobal(paths: ["container-registries", "container-registries/*"])
                }
                await loadRegistries(refresh: true)
            }
        }
        .alert(
            "Couldn't Delete Registry",
            isPresented: Binding(
                get: { actionErrorMessage != nil },
                set: { if !$0 { actionErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { actionErrorMessage = nil }
        } message: {
            Text(actionErrorMessage ?? "")
        }
    }

    private func loadRegistries(refresh: Bool = false) async {
        guard manager.currentUser?.isAdmin == true, let client = manager.client else { return }
        let generation = pagination.reset()
        isLoadingMore = false
        if registries.isEmpty { isLoading = true }
        errorMessage = nil
        loadMoreError = nil
        defer {
            if pagination.accepts(generation) {
                isLoading = false
            }
        }
        do {
            let response = try await client.registries.listPaginated(
                search: debouncedSearchText.isEmpty ? nil : debouncedSearchText,
                start: 0,
                limit: Self.pageSize
            )
            applyPage(response, reset: true, requestedStart: 0, generation: generation)
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
            let response = try await client.registries.listPaginated(
                search: debouncedSearchText.isEmpty ? nil : debouncedSearchText,
                start: start,
                limit: Self.pageSize
            )
            applyPage(response, reset: false, requestedStart: start, generation: generation)
        } catch {
            guard pagination.accepts(generation) else { return }
            loadMoreError = friendlyErrorMessage(error)
        }
    }

    private func applyPage(
        _ response: PaginatedResponse<ContainerRegistry>,
        reset: Bool,
        requestedStart: Int,
        generation: Int
    ) {
        guard pagination.receive(
            pagination: response.pagination,
            itemCount: response.data.count,
            requestedStart: requestedStart,
            requestedLimit: Self.pageSize,
            generation: generation
        ) else { return }
        registries = PaginationLoader.merge(
            current: registries,
            incoming: response.data,
            reset: reset
        )
        loadMoreError = nil
        errorMessage = nil
    }

    private func deleteRegistry(_ registry: ContainerRegistry) async {
        guard manager.currentUser?.isAdmin == true, let client = manager.client else { return }
        do {
            let _: DataResponse<String> = try await client.rest.delete("container-registries/\(registry.id)")
            withAnimation {
                registries.removeAll { $0.id == registry.id }
            }
            if let cached = manager.cached {
                await cached.invalidateGlobal(paths: ["container-registries", "container-registries/*"])
            }
            await loadRegistries(refresh: true)
        } catch {
            actionErrorMessage = friendlyErrorMessage(error)
        }
    }
}

struct RegistryRow: View {
    let registry: ContainerRegistry

    // Prefer a friendly name; fall back to the URL. Avoids showing the URL twice
    // when the registry's name is just its URL.
    private var title: String {
        let name = registry.name?.trimmingCharacters(in: .whitespaces) ?? ""
        if !name.isEmpty, name != registry.url { return name }
        if !registry.url.isEmpty { return registry.url }
        return name.isEmpty ? registry.id : name
    }

    // When the title already is the URL, show the registry type instead of
    // repeating it.
    private var subtitle: String {
        if title != registry.url, !registry.url.isEmpty { return registry.url }
        return typeLabel
    }

    private var typeLabel: String {
        registry.registryType == "ecr" ? "AWS ECR" : "Generic"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.title3).foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                // A frosted (non-glass) chip: a standalone .glassEffect per row
                // re-lays-out inside the List and triggers SwiftUI's "glassEffect
                // tried to update multiple times per frame" warning. Material gives
                // the same look without the per-row glass pass.
                .background(.regularMaterial, in: .circle)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !registry.enabled {
                Text("Disabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

private struct PressableRegistryRow: View {
    let registry: ContainerRegistry
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onEdit) {
            RegistryRow(registry: registry)
                // Without this, a plain-style button in a List only registers taps
                // on the opaque text/icon — the rest of the row (and its padding)
                // is dead, so users had to long-press. Make the whole row tappable.
                .contentShape(Rectangle())
        }
        .cardRowLinkStyle()
        .contextMenu {
            Button(action: onEdit) {
                Label("Edit", systemImage: "pencil")
            }
            Button(role: .destructive, action: onDelete) {
                DestructiveLabel(text: "Delete")
            }
            .tint(.red)
        } preview: {
            RowPreviewCard(
                icon: "shippingbox.fill",
                iconColor: .accentColor,
                title: registry.name ?? registry.id,
                badges: [
                    .init(text: registry.enabled ? "Enabled" : "Disabled",
                          color: registry.enabled ? .green : .secondary)
                ],
                details: [
                    .init(icon: "link", label: "URL", value: registry.url)
                ]
            )
        }
    }
}
