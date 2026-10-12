import Arcane
import SwiftUI

struct ImagesView: View {
    private static let pageSize = 50

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(EnvironmentsStore.self) private var environmentsStore
    let environmentID: EnvironmentID
    let environmentName: String
    /// All Environments preview: list and act on resources from every enabled environment.
    var allEnvironments = false

    @State private var list = EnvironmentPagedList<ImageSummary>(pageSize: Self.pageSize)
    @State private var actionErrorMessage: String?
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    /// Update check results per environment: the same reference can differ between environments.
    @State private var updateInfo: [EnvironmentID: [String: ImageUpdateResponse]] = [:]
    @State private var showPullSheet = false
    @State private var pendingDestructive: ImageDestructive?
    @State private var pendingMaintenanceAction: AllEnvironmentsMaintenanceAction?
    @State private var showPruneSheet = false
    @State private var showUploadSheet = false
    /// Environment picked for Pull, Upload, or Prune Options.
    @State private var targetEnvironmentID: EnvironmentID?
    @State private var updatesEnvironmentID: EnvironmentID?
    @State private var loadGeneration = 0
    @State private var showFilterSheet = false
    @State private var environmentFilter: EnvironmentID?
    @State private var tagsFilter = ImageTagsFilter.all
    @State private var sortOrder = ListSortOrder.ascending
    @State private var sections: [StableListSection<String, ImageRowModel>] = []

    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var isBulkRunning = false
    @State private var bulkRunningActionID: String?

    /// Quick prune and per-image delete share one `.deleteConfirmation` cover
    /// (one full-screen cover per view). The Prune Options form is separate.
    private enum ImageDestructive {
        case prune(ResourcePruneAction)
        case delete(EnvironmentItem<ImageSummary>)
        case bulkDelete([String])
    }

    private var images: [EnvironmentItem<ImageSummary>] { list.items }

    /// The environments this list covers, known before the first load finishes.
    private var listEnvironments: [ListEnvironment] {
        allEnvironments ? list.environments : [ListEnvironment(id: environmentID, name: nil)]
    }

    private var activeFilterCount: Int {
        var count = tagsFilter != .all ? 1 : 0
        if environmentFilter != nil { count += 1 }
        return count
    }

    /// Filters + sorts once and partitions in a single pass. Pure — reads the
    /// current inputs and returns the grouped sections without touching state.
    private func computeSections() -> [StableListSection<String, ImageRowModel>] {
        let query = debouncedSearchText
        let filtered = images.filter { image in
            guard environmentFilter == nil || image.environmentID == environmentFilter else { return false }
            let matchesSearch =
                query.isEmpty || image.displayName.localizedCaseInsensitiveContains(query)
                || image.value.id.localizedCaseInsensitiveContains(query)
            let isTagged = image.repoTags.contains(where: { $0 != "<none>:<none>" })
            let matchesTags =
                tagsFilter == .all
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
            .init(id: "unused", title: "Unused", items: unused),
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
        allEnvironments
            ? mutationStore.version(kind: .images, in: list.environments)
            : mutationStore.version(kind: .images, envID: environmentID)
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
            showSkeleton: list.isLoading && images.isEmpty,
            animatesTransition: false
        ) {
            ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } content: {
            if let error = list.errorMessage, images.isEmpty {
                ContentUnavailableView {
                    Label("Error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await loadImages() } }
                }
            } else if images.isEmpty {
                ContentUnavailableView {
                    Label("No Images", systemImage: "photo.stack")
                } description: {
                    Text(
                        allEnvironments
                            ? "No images pulled to any environment yet." : "No images pulled to this environment yet.")
                } actions: {
                    if allEnvironments {
                        EnvironmentActionButton(
                            title: "Pull Image", systemImage: "arrow.down.circle", environments: listEnvironments
                        ) { environmentID in
                            presentPull(in: environmentID)
                        }
                    } else {
                        Button("Pull Image") { presentPull(in: environmentID) }
                    }
                }
            } else {
                List(selection: BulkListSelection.binding($selection, isSelecting: isSelecting)) {
                    EnvironmentLoadFailuresSection(failures: list.failedEnvironments) {
                        Task { await loadImages() }
                    }
                    StableSectionedList(
                        sections,
                        preferredHeaderAccessorySectionID: "used",
                        headerAccessory: { _ in
                            ResourceCountLabel(
                                loadedCount: images.count,
                                totalCount: list.totalItems,
                                hasMore: list.hasMore
                            )
                        }
                    ) { image in
                        imageLink(image)
                    }

                    PaginatedListFooter(
                        hasMore: list.hasMore,
                        loadMoreError: list.loadMoreError,
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
                AppToolbarItem(placement: .navigationBarLeading) {
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
            if !isSelecting {
                AppToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showFilterSheet = true
                    } label: {
                        Image(
                            systemName: activeFilterCount > 0
                                ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
                        )
                        .appAccentToolbarSymbol()
                    }
                    .accessibilityLabel("Filter")
                }
                AppToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            enterSelectionMode()
                        } label: {
                            Label("Select", systemImage: "checklist")
                        }
                        Divider()
                        if allEnvironments {
                            // Update checks run per environment; pick which one to open.
                            EnvironmentActionButton(
                                title: "Updates", systemImage: "arrow.up.arrow.down.circle",
                                environments: listEnvironments
                            ) { environmentID in
                                updatesEnvironmentID = environmentID
                            }
                        } else {
                            NavigationLink(
                                destination: ImageUpdatesView(environmentID: environmentID, images: images.map(\.value))
                            ) {
                                Label("Updates", systemImage: "arrow.up.arrow.down.circle")
                            }
                        }
                        NavigationLink(
                            destination: AllVulnerabilitiesView(
                                environmentID: environmentID, allEnvironments: allEnvironments)
                        ) {
                            Label("Security", systemImage: "shield")
                        }
                        EnvironmentActionButton(
                            title: "Upload tarball…", systemImage: "square.and.arrow.up",
                            environments: listEnvironments
                        ) { environmentID in
                            targetEnvironmentID = environmentID
                            showUploadSheet = true
                        }
                        if allEnvironments {
                            Divider()
                            AllEnvironmentsMaintenanceButtons(action: $pendingMaintenanceAction)
                        }
                        Divider()
                        Group {
                            Button(role: .destructive) {
                                pendingDestructive = .prune(.images)
                            } label: {
                                DestructiveLabel(text: "Quick Prune (Dangling)")
                            }
                            Button(role: .destructive) {
                                pendingDestructive = .prune(.unusedImages)
                            } label: {
                                DestructiveLabel(text: "Prune All Unused")
                            }
                        }
                        .tint(.red)
                        .disabled(allEnvironments && AllEnvironmentsOperationStore.shared.isRunning)
                        EnvironmentActionButton(
                            title: "Prune Options…", systemImage: "slider.horizontal.3",
                            environments: listEnvironments
                        ) { environmentID in
                            targetEnvironmentID = environmentID
                            showPruneSheet = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .appAccentToolbarSymbol()
                    }
                    .accessibilityLabel("More options")
                }
            } else {
                AppToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        exitSelectionMode()
                    }
                }
            }

            if !isSelecting {
                AppToolbarItem(placement: .navigationBarTrailing) {
                    if allEnvironments {
                        EnvironmentActionButton(
                            title: "Pull Image", systemImage: "arrow.down.circle", environments: listEnvironments
                        ) { environmentID in
                            presentPull(in: environmentID)
                        }
                        .appAccentToolbarSymbol()
                        .accessibilityLabel("Pull image")
                    } else {
                        Button {
                            presentPull(in: environmentID)
                        } label: {
                            Image(systemName: "arrow.down.circle")
                                .appAccentToolbarSymbol()
                        }
                        .accessibilityLabel("Pull image")
                    }
                }
            }
        }
        .deleteConfirmation(item: $pendingDestructive) { action in
            switch action {
            case .prune(let action):
                return DeleteConfirmationConfig(
                    title: action.title,
                    message: allEnvironments ? action.allEnvironmentsMessage : action.message,
                    icon: "trash",
                    actions: [
                        DeleteConfirmationAction(title: "Prune") {
                            Task { await pruneImages(action) }
                        }
                    ]
                )
            case .delete(let image):
                return DeleteConfirmationConfig(
                    title: "Delete Image",
                    message: "Delete “\(image.displayName)”? This removes the image from the host.",
                    icon: "trash",
                    actions: [
                        DeleteConfirmationAction(title: "Delete") {
                            Task { await removeImage(image) }
                        }
                    ]
                )
            case .bulkDelete(let ids):
                return DeleteConfirmationConfig(
                    title: "Delete Images",
                    message: "Delete \(ids.count) selected image\(ids.count == 1 ? "" : "s") from the host.",
                    icon: "trash",
                    actions: [
                        DeleteConfirmationAction(title: "Delete") {
                            Task { await bulkDeleteImages(ids: ids) }
                        }
                    ]
                )
            }
        }
        .allEnvironmentsMaintenanceConfirmation(
            action: $pendingMaintenanceAction, environments: environmentsStore.enabledEnvironments
        )
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
            ImagePruneView(environmentID: targetEnvironmentID ?? environmentID) {}
        }
        .sheet(isPresented: $showFilterSheet) {
            NavigationStack {
                Form {
                    Section("Sort") {
                        Picker("Sort", selection: $sortOrder) {
                            ForEach(ListSortOrder.allCases) { order in
                                Label(order.title, systemImage: order.systemImage).tag(order)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    EnvironmentFilterSection(environments: list.environments, selection: $environmentFilter)
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
                    AppToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showFilterSheet = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationContentInteraction(.resizes)
            .presentationDragIndicator(.visible)
        }
        .task { await loadImages() }
        .refreshable { await loadImages() }
        .debounce(searchText, for: .milliseconds(200), into: $debouncedSearchText)
        .navigationDestination(for: EnvironmentItem<ImageSummary>.self) { image in
            ImageDetailView(image: image.value, environmentID: image.environmentID)
        }
        .navigationDestination(item: $updatesEnvironmentID) { environmentID in
            ImageUpdatesView(
                environmentID: environmentID,
                images: images.filter { $0.environmentID == environmentID }.map(\.value)
            )
        }
        .sheet(isPresented: $showPullSheet) {
            PullImageView(environmentID: targetEnvironmentID ?? environmentID)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showUploadSheet) {
            UploadImageView(environmentID: targetEnvironmentID ?? environmentID) {}
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: mutationVersion) { _, _ in
            Task { await loadImages() }
        }
        .onChange(of: debouncedSearchText) { rebuildSections() }
        .onChange(of: environmentFilter) { rebuildSections() }
        .onChange(of: tagsFilter) { rebuildSections() }
        .onChange(of: sortOrder) { rebuildSections() }
        .resourceActionsToolbar(
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
            ImageRow(row: row, environmentName: image.environmentName)
                .rowEnvironment(image)
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

    private func presentPull(in environmentID: EnvironmentID) {
        targetEnvironmentID = environmentID
        showPullSheet = true
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

    private func imagePreview(_ image: EnvironmentItem<ImageSummary>, state: ImageUpdateState) -> some View {
        var badges: [RowPreviewCard.PreviewBadge] = [
            .init(
                text: image.inUse ? "In Use" : "Unused",
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
        var details: [RowPreviewCard.PreviewDetail] = [
            .init(icon: "internaldrive", label: "Size", value: image.size.byteString),
            .init(icon: "number", label: "ID", value: image.value.id, monospaced: true),
        ]
        if let environmentName = image.environmentName {
            details.append(.init(icon: "server.rack", label: "Environment", value: environmentName))
        }
        return RowPreviewCard(
            icon: "photo.stack.fill",
            iconColor: .purple,
            title: image.displayName,
            badges: badges,
            details: details
        )
    }

    private func loadImages() async {
        guard let client = manager.client else { return }
        loadGeneration += 1
        let generation = loadGeneration
        let environments = await environmentsStore.listEnvironments(
            environmentID, allEnvironments: allEnvironments, manager: manager)
        await list.reload(environments, fetch: imagesPage(client: client))
        guard loadGeneration == generation, !Task.isCancelled else { return }
        // A failed environment keeps its rows, so keep their update results too.
        let failedIDs = Set(list.failedEnvironments.map(\.environment.id))
        updateInfo = updateInfo.filter { failedIDs.contains($0.key) }
        rebuildSections()
        await loadUpdateInfo(for: images.filter { !failedIDs.contains($0.environmentID) })
    }

    private func loadMore() async {
        guard let client = manager.client else { return }
        let generation = loadGeneration
        let loadedIDs = Set(images.map(\.id))
        await list.loadMore(fetch: imagesPage(client: client))
        guard loadGeneration == generation else { return }
        rebuildSections()
        await loadUpdateInfo(for: images.filter { !loadedIDs.contains($0.id) })
    }

    private func imagesPage(client: ArcaneClient) -> EnvironmentPagedList<ImageSummary>.Fetch {
        // `ImageListResponse` is Decodable-only, so we can't drive it through
        // the cache layer (which requires Codable). Fetch directly through
        // the SDK service — pull-to-refresh and pagination keep the data
        // current.
        { environmentID, start, limit in
            let query = SearchPaginationSort(start: start, limit: limit)
            let response = try await client.images.list(envID: environmentID, query: query)
            return ResourcePage(items: response.data, pagination: response.pagination)
        }
    }

    private func invalidateImageCaches(_ environmentID: EnvironmentID) async {
        guard let cached = manager.cached, let client = manager.client else { return }
        await cached.invalidate(
            envID: environmentID,
            paths: [
                client.rest.environmentPath(environmentID, "images") + "*",
                client.rest.environmentPath(environmentID, "images/*"),
            ])
    }

    /// Fetches update results for `newImages`, one request per environment.
    private func loadUpdateInfo(for newImages: [EnvironmentItem<ImageSummary>]) async {
        guard let client = manager.client else { return }
        let generation = loadGeneration
        let clientGeneration = manager.clientGeneration
        var refsByEnvironment: [EnvironmentID: [String]] = [:]
        for image in newImages {
            let refs = image.repoTags.filter { $0 != "<none>:<none>" }
            guard !refs.isEmpty else { continue }
            refsByEnvironment[image.environmentID, default: []] += refs
        }
        guard !refsByEnvironment.isEmpty else { return }
        await withTaskGroup(of: (EnvironmentID, [String: ImageUpdateInfo?]?).self) { group in
            for (environmentID, refs) in refsByEnvironment {
                group.addTask {
                    // Update info is best-effort decoration — silent failure.
                    (environmentID, try? await client.images.updateInfoByRefs(envID: environmentID, imageRefs: refs))
                }
            }
            for await (environmentID, map) in group {
                guard let map, !Task.isCancelled, generation == loadGeneration,
                    clientGeneration == manager.clientGeneration
                else { continue }
                updateInfo[environmentID, default: [:]].merge(ImageUpdateState.checkedResults(map)) { _, new in new }
                rebuildSections()
            }
        }
    }

    private func updateState(for image: EnvironmentItem<ImageSummary>) -> ImageUpdateState {
        ImageUpdateState.resolve(
            inline: image.updateInfo, references: image.repoTags, results: updateInfo[image.environmentID] ?? [:])
    }

    private func pruneImages(_ action: ResourcePruneAction) async {
        if allEnvironments {
            await AllEnvironmentsOperationStore.shared.performPrune(
                action, environments: environmentsStore.enabledEnvironments, manager: manager)
            return
        }
        guard let client = manager.client else { return }
        do {
            try await action.perform(client: client, environmentID: environmentID)
            await invalidateImageCaches(environmentID)
            mutationStore.markChanged(kind: .images, envID: environmentID)
        } catch {
            actionErrorMessage = friendlyErrorMessage(error)
        }
    }

    private func removeImage(_ image: EnvironmentItem<ImageSummary>) async {
        guard let client = manager.client else { return }
        do {
            try await client.images.remove(envID: image.environmentID, id: image.value.id)
            withAnimation {
                list.update { $0.removeAll { $0.id == image.id } }
                rebuildSections()
            }
            await invalidateImageCaches(image.environmentID)
            mutationStore.markChanged(kind: .images, envID: image.environmentID)
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
        let targets = images.filter { ids.contains($0.id) }
        let byID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
        let result = await BulkActionRunner.run(ids: targets.map(\.id)) { id in
            guard let image = byID[id] else { return }
            try await client.images.remove(envID: image.environmentID, id: image.value.id)
        }
        let failedIDs = Set(result.failed.map(\.id))
        let removedIDs = Set(targets.map(\.id).filter { !failedIDs.contains($0) })
        list.update { $0.removeAll { removedIDs.contains($0.id) } }
        rebuildSections()
        for environment in Set(targets.map(\.environmentID)) {
            await invalidateImageCaches(environment)
            mutationStore.markChanged(kind: .images, envID: environment)
        }
        exitSelectionMode()
        if result.failed.isEmpty {
            showToast(.success("Deleted \(result.succeeded) image\(result.succeeded == 1 ? "" : "s")"))
            ReviewPrompter.shared.recordSuccess()
        } else {
            showToast(.error("\(result.failed.count) of \(targets.count) failed"))
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

    var environmentName: String? = nil

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
                EnvironmentLabel(name: environmentName)
            }

            Spacer(minLength: 0)
        }

        .accessibilityElement(children: .combine)
    }
}

struct ImageRowModel: Identifiable {
    let image: EnvironmentItem<ImageSummary>
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
    @SwiftUI.Environment(EnvironmentsStore.self) private var environmentsStore
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
                        Button {
                            imageName = result.name
                        } label: {
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
                searchResults = []
                searchError = nil
                let term = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !term.isEmpty, let client = manager.client else { return }
                searching = true
                defer { searching = false }
                do {
                    try await Task.sleep(for: .milliseconds(350))
                    let results = try await client.images.search(envID: environmentID, term: term)
                    guard !Task.isCancelled else { return }
                    searchResults = results
                } catch is CancellationError {} catch ArcaneError.notFound {
                    searchError = "Image search is not available on this server."
                } catch { searchError = error.localizedDescription }
            }
            .onChange(of: manager.clientGeneration) { dismiss() }
            .onChange(of: manager.activeEnvironmentID) { dismiss() }
            .navigationTitle("Pull Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                AppToolbarItem(placement: .confirmationAction) {
                    Button("Pull") { startPull() }
                        .disabled(imageName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func startPull() {
        let reference = imageName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty, manager.permissions.has("images:pull", in: environmentID),
            manager.acceptsEnvironmentContext(environmentID)
        else { return }
        dismiss()
        DeploymentActivityStore.shared.start(
            kind: .imagePull,
            envID: environmentID,
            targetID: reference,
            targetName: reference,
            environmentName: environmentsStore.displayName(for: environmentID) ?? manager.activeEnvironmentName,
            manager: manager,
            mutationStore: mutationStore,
            presentSheet: false
        )
    }
}
