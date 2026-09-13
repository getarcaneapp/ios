import SwiftUI
import Arcane

struct ImagesView: View {
    private static let pageSize = 50

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    let environmentID: EnvironmentID
    let environmentName: String


    @State private var images: [ImageSummary] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var actionErrorMessage: String?
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var updateInfo: [String: ImageUpdateResponse] = [:]
    @State private var showPullSheet = false
    @State private var pendingDestructive: ImageDestructive?
    @State private var showPruneSheet = false
    @State private var showUploadSheet = false
    @State private var currentPage = 1
    @State private var hasMore = false
    @State private var totalItemCount: Int64?
    @State private var isLoadingMore = false
    @State private var loadMoreError: String?
    @State private var loadGeneration = 0
    @State private var showFilterSheet = false
    @State private var tagsFilter = ImageTagsFilter.all
    @State private var sortOrder = ListSortOrder.ascending
    @State private var sections: [StableListSection<String, ImageRowModel>] = []

    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var isBulkRunning = false
    @State private var bulkRunningActionID: String?

    private enum ImageTagsFilter: String, CaseIterable {
        case all = "All", tagged = "Tagged", untagged = "Untagged"
    }

    /// Quick prune and per-image delete share one `.deleteConfirmation` cover
    /// (one full-screen cover per view). The Prune Options form is separate.
    private enum ImageDestructive {
        case prune
        case delete(ImageSummary)
        case bulkDelete([String])
    }

    private var activeFilterCount: Int { tagsFilter != .all ? 1 : 0 }

    /// Filters + sorts once and partitions in a single pass. Pure — reads the
    /// current inputs and returns the grouped sections without touching state.
    private func computeSections() -> [StableListSection<String, ImageRowModel>] {
        let query = debouncedSearchText
        let filtered = images.filter { image in
            let matchesSearch = query.isEmpty ||
                image.displayName.localizedCaseInsensitiveContains(query) ||
                image.id.localizedCaseInsensitiveContains(query)
            let isTagged = image.repoTags.contains(where: { $0 != "<none>:<none>" })
            let matchesTags = tagsFilter == .all
                || (tagsFilter == .tagged && isTagged)
                || (tagsFilter == .untagged && !isTagged)
            return matchesSearch && matchesTags
        }
        .sorted {
            sortOrder.areInIncreasingOrder($0.displayName, $1.displayName)
        }
        var used: [ImageRowModel] = []
        var unused: [ImageRowModel] = []
        for image in filtered {
            let row = ImageRowModel(
                image: image,
                displayName: image.displayName,
                sizeText: image.size.byteString,
                updateState: updateState(for: image)
            )
            if image.inUse {
                used.append(row)
            } else {
                unused.append(row)
            }
        }
        return [
            .init(id: "used", title: "Used", items: used),
            .init(id: "unused", title: "Unused", items: unused)
        ]
    }

    /// Refresh the cached `sections`. Called only when an input that affects
    /// grouping actually changes (search settle, sort, filter, or the source
    /// list) — never on every body evaluation.
    private func rebuildSections() {
        sections = computeSections()
        pruneSelection(validIDs: Set(images.map(\.id)))
    }

    private var isAdmin: Bool {
        manager.currentUser?.isAdmin == true
    }

    private var mutationVersion: Int {
        mutationStore.version(kind: .images, envID: environmentID)
    }

    /// Per-section item counts — drives the List's implicit reflow animation so a
    /// programmatic insert/remove animates too.


    private var selectedImageIDs: [String] {
        images.filter { selection.contains($0.id) }.map(\.id)
    }

    private var bulkPrimaryItem: ActionButtonItem? {
        guard !selection.isEmpty else { return nil }
        return ActionButtonItem(
            id: "bulk-delete",
            title: "Delete",
            systemImage: "trash",
            tint: .red
        ) {
            pendingDestructive = .bulkDelete(selectedImageIDs)
        }
    }

    var body: some View {
        LoadingCrossfade(
            showSkeleton: isLoading && images.isEmpty,
            animatesTransition: false
        ) {
            ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } content: {
            if let error = errorMessage, images.isEmpty {
                ContentUnavailableView {
                    Label("Error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await loadImages(reset: true) } }
                }
            } else if images.isEmpty {
                ContentUnavailableView {
                    Label("No Images", systemImage: "photo.stack")
                } description: {
                    Text("No images pulled to this environment yet.")
                } actions: {
                    Button("Pull Image") { showPullSheet = true }
                }
            } else {
                List(selection: BulkListSelection.binding($selection, isSelecting: isSelecting)) {
                    StableSectionedList(
                        sections,
                        preferredHeaderAccessorySectionID: "used",
                        headerAccessory: { _ in
                            ResourceCountLabel(
                                loadedCount: images.count,
                                totalCount: totalItemCount,
                                hasMore: hasMore
                            )
                        }
                    ) { image in
                        imageLink(image)
                    }

                    PaginatedListFooter(
                        hasMore: hasMore,
                        loadMoreError: loadMoreError,
                        onRetry: { Task { await loadMore() } },
                        onLoadMore: { Task { await loadMore() } }
                    )
                }
                .listStyle(.insetGrouped)
                .environment(\.editMode, .constant(isSelecting ? EditMode.active : EditMode.inactive))

            }
        }
        .navigationTitle("Images")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search images")
        .toolbar {
            if isAdmin {
                ToolbarItem(placement: .navigationBarLeading) {
                    NavigationLink(destination: ContainerRegistriesView()) {
                        // `key.shield` is an SF Symbols 7 (iOS 26) glyph; fall back
                        // to `lock.shield` (iOS 13+) so iOS 18 doesn't render blank.
                        Group {
                            if #available(iOS 26, *) {
                                Image(systemName: "key.shield")
                            } else {
                                Image(systemName: "lock.shield")
                            }
                        }
                        .appAccentToolbarSymbol()
                    }
                }
            }
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
                    if !isSelecting {
                        Divider()
                        NavigationLink(destination: ImageUpdatesView(environmentID: environmentID, images: images)) {
                            Label("Updates", systemImage: "arrow.up.arrow.down.circle")
                        }
                        NavigationLink(destination: AllVulnerabilitiesView(environmentID: environmentID)) {
                            Label("Vulnerabilities", systemImage: "shield")
                        }
                        Button {
                            showUploadSheet = true
                        } label: {
                            Label("Upload tarball…", systemImage: "square.and.arrow.up")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .appAccentToolbarSymbol()
                }
                .accessibilityLabel("More options")
            }
            if #available(iOS 26, *) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
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
                    Button { showPullSheet = true } label: {
                        Image(systemName: "arrow.down.circle")
                            .appAccentToolbarSymbol()
                    }
                    .accessibilityLabel("Pull image")
                }
                if #available(iOS 26, *) {
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            pendingDestructive = .prune
                        } label: {
                            DestructiveLabel(text: "Quick Prune (Dangling)")
                        }
                        .tint(.red)
                        Button {
                            showPruneSheet = true
                        } label: {
                            Label("Prune Options…", systemImage: "slider.horizontal.3")
                        }
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .accessibilityLabel("Prune images")
                }
            }
        }
        .deleteConfirmation(item: $pendingDestructive) { action in
            switch action {
            case .prune:
                return DeleteConfirmationConfig(
                    title: "Prune Dangling Images",
                    message: "Remove all dangling images. This cannot be undone.",
                    icon: "trash",
                    actions: [DeleteConfirmationAction(title: "Prune") {
                        Task { await pruneImages() }
                    }]
                )
            case .delete(let image):
                return DeleteConfirmationConfig(
                    title: "Delete Image",
                    message: "Delete “\(image.displayName)”? This removes the image from the host.",
                    icon: "trash",
                    actions: [DeleteConfirmationAction(title: "Delete") {
                        Task { await removeImage(image) }
                    }]
                )
            case .bulkDelete(let ids):
                return DeleteConfirmationConfig(
                    title: "Delete Images",
                    message: "Delete \(ids.count) selected image\(ids.count == 1 ? "" : "s") from the host.",
                    icon: "trash",
                    actions: [DeleteConfirmationAction(title: "Delete") {
                        Task { await bulkDeleteImages(ids: ids) }
                    }]
                )
            }
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(
                get: { actionErrorMessage != nil },
                set: { if !$0 { actionErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { actionErrorMessage = nil }
        } message: {
            Text(actionErrorMessage ?? "")
        }
        .sheet(isPresented: $showPruneSheet) {
            ImagePruneView(environmentID: environmentID) {}
        }
        .sheet(isPresented: $showFilterSheet) {
            NavigationStack {
                Form {
                    Section("Tags") {
                        Picker("Tags", selection: $tagsFilter) {
                            ForEach(ImageTagsFilter.allCases, id: \.self) { filter in
                                Text(filter.rawValue).tag(filter)
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
        .task { await loadImages(reset: true) }
        .refreshable { await loadImages(reset: true, refresh: true) }
        .debounce(searchText, for: .milliseconds(200), into: $debouncedSearchText)
        .navigationDestination(for: ImageSummary.self) { image in
            ImageDetailView(image: image, environmentID: environmentID)
        }
        .sheet(isPresented: $showPullSheet) {
            PullImageView(environmentID: environmentID)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showUploadSheet) {
            UploadImageView(environmentID: environmentID) {}
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: mutationVersion) { _, _ in
            Task { await loadImages(reset: true, refresh: true) }
        }
        .onChange(of: debouncedSearchText) { rebuildSections() }
        .onChange(of: tagsFilter) { rebuildSections() }
        .onChange(of: sortOrder) { rebuildSections() }
        .morphingActions(
            primary: bulkPrimaryItem,
            runningItemID: bulkRunningActionID,
            isDisabled: isBulkRunning,
            resourceName: "\(selection.count) selected",
            active: isSelecting && !selection.isEmpty
        )
    }

    private func imageLink(_ row: ImageRowModel) -> some View {
        let image = row.image
        return NavigationLink(value: image) {
            ImageRow(row: row)
        }
        .contextMenu {
            if !isSelecting {
                Button(role: .destructive) {
                    pendingDestructive = .delete(image)
                } label: {
                    DestructiveLabel(text: "Delete")
                }
                .tint(.red)
            }
        } preview: {
            if !isSelecting {
                imagePreview(image, state: row.updateState)
                    .environment(manager)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isSelecting {
                Button {
                    pendingDestructive = .delete(image)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
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

    private func imagePreview(_ image: ImageSummary, state: ImageUpdateState) -> some View {
        var badges: [RowPreviewCard.PreviewBadge] = [
            .init(text: image.inUse ? "In Use" : "Unused",
                  color: image.inUse ? .green : .secondary)
        ]
        switch state {
        case .upToDate:
            badges.append(.init(text: "Up to Date", color: .green))
        case .hasUpdate:
            badges.append(.init(text: "Update Available", color: .accentColor))
        case .error:
            badges.append(.init(text: "Check Failed", color: .red))
        case .unknown:
            break
        }
        return RowPreviewCard(
            icon: "photo.stack.fill",
            iconColor: .purple,
            title: image.displayName,
            badges: badges,
            details: [
                .init(icon: "internaldrive", label: "Size", value: image.size.byteString),
                .init(icon: "number", label: "ID", value: image.id, monospaced: true)
            ]
        )
    }

    private func loadImages(reset: Bool, refresh: Bool = false) async {
        guard let client = manager.client else { return }
        loadGeneration += 1
        let generation = loadGeneration
        let requestedPage = reset ? 1 : currentPage + 1
        let start = max(0, (requestedPage - 1) * Self.pageSize)
        if images.isEmpty { isLoading = true }
        errorMessage = nil
        loadMoreError = nil
        defer {
            if loadGeneration == generation {
                isLoading = false
            }
        }
        do {
            // `ImageListResponse` is Decodable-only, so we can't drive it through
            // the cache layer (which requires Codable). Fetch directly through
            // the SDK service — pull-to-refresh and pagination keep the data
            // current.
            let query = SearchPaginationSort(start: start, limit: Self.pageSize)
            let response = try await client.images.list(envID: environmentID, query: query)
            applyImagesPage(response, reset: reset, generation: generation)
            await loadUpdateInfo(for: response.data)
        } catch {
            guard loadGeneration == generation else { return }
            if reset { errorMessage = friendlyErrorMessage(error) }
            else { loadMoreError = friendlyErrorMessage(error) }
        }
    }

    private func applyImagesPage(_ response: ImageListResponse, reset: Bool, generation: Int) {
        guard loadGeneration == generation else { return }
        if reset {
            images = response.data
            updateInfo = [:]
        } else {
            let existing = Set(images.map(\.id))
            images.append(contentsOf: response.data.filter { !existing.contains($0.id) })
        }
        currentPage = max(Int(response.pagination.currentPage), 1)
        hasMore = response.pagination.currentPage < response.pagination.totalPages
        if response.pagination.totalItems >= 0 {
            totalItemCount = response.pagination.totalItems
        } else if reset {
            totalItemCount = nil
        }
        rebuildSections()
    }

    private func invalidateImageCaches() async {
        guard let cached = manager.cached, let client = manager.client else { return }
        await cached.invalidate(envID: environmentID, paths: [
            client.rest.environmentPath(environmentID, "images") + "*",
            client.rest.environmentPath(environmentID, "images/*")
        ])
    }

    private func loadUpdateInfo(for newImages: [ImageSummary]) async {
        guard let client = manager.client else { return }
        let generation = loadGeneration
        let clientGeneration = manager.clientGeneration
        let refs = newImages
            .flatMap { $0.repoTags }
            .filter { $0 != "<none>:<none>" }
        guard !refs.isEmpty else { return }
        do {
            let map = try await client.images.updateInfoByRefs(envID: environmentID, imageRefs: refs)
            guard !Task.isCancelled, generation == loadGeneration,
                  clientGeneration == manager.clientGeneration else { return }
            updateInfo.merge(map.compactMapValues { info in
                guard let info, info.hasCheckResult || info.checkTime != nil else { return nil }
                return info.asUpdateResponse
            }) { _, new in new }
            rebuildSections()
        } catch {
            // Update info is best-effort decoration — silent failure.
        }
    }

    private func updateState(for image: ImageSummary) -> ImageUpdateState {
        ImageUpdateState.resolve(inline: image.updateInfo, references: image.repoTags, results: updateInfo)
    }

    private func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        await loadImages(reset: false)
    }

    private func pruneImages() async {
        guard let client = manager.client else { return }
        do {
            _ = try await client.images.prune(envID: environmentID, mode: "dangling")
            await invalidateImageCaches()
            mutationStore.markChanged(kind: .images, envID: environmentID)
        } catch {
            actionErrorMessage = friendlyErrorMessage(error)
        }
    }

    private func removeImage(_ image: ImageSummary) async {
        guard let client = manager.client else { return }
        do {
            try await client.images.remove(envID: environmentID, id: image.id)
            withAnimation {
                images.removeAll { $0.id == image.id }
                rebuildSections()
            }
            await invalidateImageCaches()
            mutationStore.markChanged(kind: .images, envID: environmentID)
        } catch {
            actionErrorMessage = friendlyErrorMessage(error)
        }
    }

    private func bulkDeleteImages(ids: [String]) async {
        guard let baseClient = manager.client else { return }
        isBulkRunning = true
        bulkRunningActionID = "bulk-delete"
        defer {
            isBulkRunning = false
            bulkRunningActionID = nil
        }
        let client: ArcaneClient
        do {
            client = try ActivityBatchID.scopedClient(baseClient)
        } catch {
            showToast(.error("Couldn't start bulk deletion"))
            return
        }
        let result = await BulkActionRunner.run(ids: ids) { id in
            try await client.images.remove(envID: environmentID, id: id)
        }
        let failedIDs = Set(result.failed.map(\.id))
        let removedIDs = Set(ids.filter { !failedIDs.contains($0) })
        images.removeAll { removedIDs.contains($0.id) }
        rebuildSections()
        await invalidateImageCaches()
        mutationStore.markChanged(kind: .images, envID: environmentID)
        exitSelectionMode()
        if result.failed.isEmpty {
            showToast(.success("Deleted \(result.succeeded) image\(result.succeeded == 1 ? "" : "s")"))
            ReviewPrompter.shared.recordSuccess()
        } else {
            showToast(.error("\(result.failed.count) of \(ids.count) failed"))
        }
    }
}

struct ImageRow: View {
    let row: ImageRowModel

    // Dense scrolling lists are a poor fit for per-row live Liquid Glass: the
    // compositor can thrash as rows enter/leave the viewport, producing the
    // "glassEffect() tried to update multiple times per frame" warning and
    // visible hitching. Use a static tinted chip here instead.
    private let iconTint = Color.purple

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.stack.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)

                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(row.displayName)
                    .font(.body)
                    .lineLimit(nil)
                HStack(spacing: 6) {
                    Text(row.sizeText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    UpdateStateBadge(state: row.updateState)
                }
            }

            Spacer(minLength: 0)
        }

        .accessibilityElement(children: .combine)
    }
}

struct ImageRowModel: Identifiable {
    let image: ImageSummary
    let displayName: String
    let sizeText: String
    let updateState: ImageUpdateState

    var id: String { image.id }
}

/// Input-only sheet: collects the image reference, then hands the pull to
/// `DeploymentActivityStore`, which owns the floating pill, the stream sheet,
/// and the Live Activity — the same treatment as project deploys. The pill
/// appears as this sheet dismisses (presenting the stream sheet mid-dismissal
/// would race the presentation), and tapping it opens the full log.
struct PullImageView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let environmentID: EnvironmentID

    @State private var imageName = ""
    @State private var searchTerm = ""
    @State private var searchResults: [ImageSearchResult] = []
    @State private var searching = false
    @State private var searchError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Pull Image") {
                    FormTextField(
                        title: "Image",
                        placeholder: "nginx:latest",
                        text: $imageName,
                        autocapitalization: .never,
                        autocorrectionDisabled: true,
                        helper: "Include a tag when you do not want Docker to assume latest."
                    )
                }
                Section("Search Docker Hub") {
                    TextField("Search repositories", text: $searchTerm)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if searching { ProgressView() }
                    if let searchError { Text(searchError).foregroundStyle(.secondary) }
                    ForEach(searchResults) { result in
                        Button { imageName = result.name } label: {
                            VStack(alignment: .leading) {
                                Text(result.name)
                                Text(result.description).font(.caption).lineLimit(2)
                                Text("\(String(result.starCount)) stars\(result.official ? " · Official" : "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .task(id: "\(manager.serverURL)|\(manager.clientGeneration)|\(environmentID.rawValue)|\(searchTerm)") {
                searchResults = []; searchError = nil
                let term = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !term.isEmpty, let client = manager.client else { return }
                searching = true
                defer { searching = false }
                do {
                    try await Task.sleep(for: .milliseconds(350))
                    let results = try await client.images.search(envID: environmentID, term: term)
                    guard !Task.isCancelled else { return }
                    searchResults = results
                } catch is CancellationError { }
                catch ArcaneError.notFound { searchError = "Image search is not available on this server." }
                catch { searchError = error.localizedDescription }
            }
            .onChange(of: manager.clientGeneration) { dismiss() }
            .onChange(of: manager.activeEnvironmentID) { dismiss() }
            .navigationTitle("Pull Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pull") { startPull() }
                        .disabled(imageName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func startPull() {
        let reference = imageName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty, manager.permissions.has("images:pull", in: environmentID), manager.activeEnvironmentID == environmentID else { return }
        dismiss()
        DeploymentActivityStore.shared.start(
            kind: .imagePull,
            envID: environmentID,
            targetID: reference,
            targetName: reference,
            environmentName: manager.activeEnvironmentName,
            manager: manager,
            mutationStore: mutationStore,
            presentSheet: false
        )
    }
}
