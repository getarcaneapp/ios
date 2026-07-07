import SwiftUI
import Arcane

struct ImagesView: View {
    private static let pageSize = 50

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    let environmentID: EnvironmentID
    let environmentName: String

    @Namespace private var heroTransition

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
    @State private var isLoadingMore = false
    @State private var loadGeneration = 0
    @State private var showFilterSheet = false
    @State private var tagsFilter = ImageTagsFilter.all
    @State private var sortOrder = ListSortOrder.ascending
    @State private var sections: [StableListSection<String, ImageRowModel>] = []

    private enum ImageTagsFilter: String, CaseIterable {
        case all = "All", tagged = "Tagged", untagged = "Untagged"
    }

    /// Quick prune and per-image delete share one `.deleteConfirmation` cover
    /// (one full-screen cover per view). The Prune Options form is separate.
    private enum ImageDestructive {
        case prune
        case delete(ImageSummary)
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
    private func rebuildSections(animated: Bool = false) {
        let new = computeSections()
        if animated {
            withAnimation(Motion.reduced(Motion.reflow, reduceMotion: reduceMotion)) { sections = new }
        } else {
            sections = new
        }
    }

    private var isAdmin: Bool {
        manager.currentUser?.isAdmin == true
    }

    private var mutationVersion: Int {
        mutationStore.version(kind: .images, envID: environmentID)
    }

    /// Per-section item counts — drives the List's implicit reflow animation so a
    /// programmatic insert/remove animates too.
    private var sectionCounts: [Int] { sections.map(\.items.count) }

    var body: some View {
        LoadingCrossfade(showSkeleton: isLoading && images.isEmpty) {
            SkeletonListLoadingView()
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
                List {
                    StableSectionedList(sections) { image in
                        imageLink(image)
                    }

                    if hasMore {
                        SkeletonListRow()
                            .skeletonShimmer()
                            .onAppear {
                                Task { await loadMore() }
                            }
                    }
                }
                .listStyle(.insetGrouped)
                .motionAwareAnimation(Motion.reflow, value: sectionCounts)
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
                        if #available(iOS 26, *) {
                            Image(systemName: "key.shield")
                        } else {
                            Image(systemName: "lock.shield")
                        }
                    }
                }
            }
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
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More options")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showPullSheet = true } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .accessibilityLabel("Pull image")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        pendingDestructive = .prune
                    } label: {
                        Label("Quick Prune (Dangling)", systemImage: "trash")
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
                            ForEach(ImageTagsFilter.allCases, id: \.self) { f in
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
            .presentationDragIndicator(.visible)
        }
        .task { await loadImages(reset: true) }
        .refreshable { await loadImages(reset: true, refresh: true) }
        .debounce(searchText, for: .milliseconds(200), into: $debouncedSearchText)
        .navigationDestination(for: ImageSummary.self) { image in
            ImageDetailView(image: image, environmentID: environmentID)
                .pageEntranceFromTop()
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
        .onChange(of: sortOrder) { rebuildSections(animated: true) }
    }

    private func imageLink(_ row: ImageRowModel) -> some View {
        let image = row.image
        return NavigationLink(value: image) {
            ImageRow(row: row)
        }
        .matchedTransitionSource(id: image.id, in: heroTransition)
        .contextMenu {
            Button(role: .destructive) {
                pendingDestructive = .delete(image)
            } label: {
                DestructiveLabel(text: "Delete")
            }
            .tint(.red)
        } preview: {
            imagePreview(image, state: row.updateState)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                pendingDestructive = .delete(image)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
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
            errorMessage = friendlyErrorMessage(error)
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
        let refs = newImages
            .flatMap { $0.repoTags }
            .filter { $0 != "<none>:<none>" }
        guard !refs.isEmpty else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "image-updates/by-refs")
            let query = [URLQueryItem(name: "imageRefs", value: refs.joined(separator: ","))]
            let map: BatchImageUpdateResponse = try await client.rest.get(path, query: query)
            updateInfo.merge(map) { _, new in new }
            rebuildSections()
        } catch {
            // Update info is best-effort decoration — silent failure.
        }
    }

    private func updateState(for image: ImageSummary) -> ImageUpdateState {
        let tags = image.repoTags
        for tag in tags where tag != "<none>:<none>" {
            if let info = updateInfo[tag] {
                if let err = info.error, !err.isEmpty { return .error(err) }
                if info.hasUpdate { return .hasUpdate }
                return .upToDate
            }
        }
        return .unknown
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
            let path = client.rest.environmentPath(environmentID, "images/\(image.id)")
            let _: DataResponse<String> = try await client.rest.delete(path)
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
}

enum ImageUpdateState: Equatable {
    case unknown
    case upToDate
    case hasUpdate
    case error(String)
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
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(iconTint, in: .circle)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(row.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(row.sizeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if row.updateState != .unknown {
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    UpdateStateBadge(state: row.updateState)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
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

struct UpdateStateBadge: View {
    let state: ImageUpdateState

    var body: some View {
        switch state {
        case .unknown:
            EmptyView()
        case .upToDate:
            badge("Up to date", systemImage: "checkmark.seal.fill", color: .green)
        case .hasUpdate:
            badge("Update available", systemImage: "arrow.up.circle.fill", color: .accentColor)
        case .error(let message):
            badge("Update check failed", systemImage: "exclamationmark.triangle.fill", color: .red,
                  accessibility: "Update check failed: \(message)")
        }
    }

    // A `Label` adds a wide icon-to-title gap; a tight HStack keeps the badge compact.
    private func badge(_ text: String, systemImage: String, color: Color, accessibility: String? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(color)
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility ?? text)
    }
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
            }
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
        guard !reference.isEmpty else { return }
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

