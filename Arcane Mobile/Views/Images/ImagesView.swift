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
    @State private var showPruneConfirm = false
    @State private var showPruneSheet = false
    @State private var showUploadSheet = false
    @State private var currentPage = 1
    @State private var hasMore = false
    @State private var isLoadingMore = false
    @State private var loadGeneration = 0
    @State private var showFilterSheet = false
    @State private var tagsFilter = ImageTagsFilter.all
    @State private var sortOrder = ListSortOrder.ascending
    @State private var sections: [StableListSection<String, ImageSummary>] = []

    private enum ImageTagsFilter: String, CaseIterable {
        case all = "All", tagged = "Tagged", untagged = "Untagged"
    }

    private var activeFilterCount: Int { tagsFilter != .all ? 1 : 0 }

    /// Filters + sorts once and partitions in a single pass. Pure — reads the
    /// current inputs and returns the grouped sections without touching state.
    private func computeSections() -> [StableListSection<String, ImageSummary>] {
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
        var used: [ImageSummary] = []
        var unused: [ImageSummary] = []
        for image in filtered {
            if image.inUse { used.append(image) } else { unused.append(image) }
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
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { sections = new }
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

    var body: some View {
        Group {
            if isLoading && images.isEmpty {
                SkeletonListLoadingView()
            } else if let error = errorMessage, images.isEmpty {
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
                        .buttonStyle(.borderedProminent)
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
            }
        }
        .navigationTitle("Images")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search images")
        .toolbar {
            if isAdmin {
                ToolbarItem(placement: .navigationBarLeading) {
                    NavigationLink(destination: ContainerRegistriesView()) {
                        Image(systemName: "key.shield")
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
                    Button {
                        showPruneConfirm = true
                    } label: {
                        Label("Quick Prune (Dangling)", systemImage: "trash")
                    }
                    Button {
                        showPruneSheet = true
                    } label: {
                        Label("Prune Options…", systemImage: "slider.horizontal.3")
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Prune images")
            }
        }
        .alert("Prune Dangling Images", isPresented: $showPruneConfirm) {
            Button("Prune", role: .destructive) { Task { await pruneImages() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove all dangling images. This cannot be undone.")
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
        }
        .task { await loadImages(reset: true) }
        .refreshable { await loadImages(reset: true, refresh: true) }
        .debounce(searchText, for: .milliseconds(200), into: $debouncedSearchText)
        .navigationDestination(for: ImageSummary.self) { image in
            ImageDetailView(image: image, environmentID: environmentID)
                .navigationTransition(.zoom(sourceID: image.id, in: heroTransition))
        }
        .sheet(isPresented: $showPullSheet) {
            PullImageView(environmentID: environmentID) {}
        }
        .sheet(isPresented: $showUploadSheet) {
            UploadImageView(environmentID: environmentID) {}
        }
        .onChange(of: mutationVersion) { _, _ in
            Task { await loadImages(reset: true, refresh: true) }
        }
        .onChange(of: debouncedSearchText) { rebuildSections() }
        .onChange(of: tagsFilter) { rebuildSections() }
        .onChange(of: sortOrder) { rebuildSections(animated: true) }
    }

    private func imageLink(_ image: ImageSummary) -> some View {
        let state = updateState(for: image)
        return NavigationLink(value: image) {
            ImageRow(image: image, updateState: state)
        }
        .matchedTransitionSource(id: image.id, in: heroTransition)
        .contextMenu {
            Button(role: .destructive) {
                Task { await removeImage(image) }
            } label: {
                DestructiveLabel(text: "Delete")
            }
            .tint(.red)
        } preview: {
            imagePreview(image, state: state)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await removeImage(image) }
            } label: {
                DestructiveLabel(text: "Delete")
            }
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
    let image: ImageSummary
    var updateState: ImageUpdateState = .unknown

    var body: some View {
        HStack(spacing: 12) {
            if #available(iOS 26, *) {
                Image(systemName: "photo.stack.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular.tint(.purple), in: .circle)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "photo.stack.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.purple, in: .circle)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(image.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    UpdateStateBadge(state: updateState)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct UpdateStateBadge: View {
    let state: ImageUpdateState

    var body: some View {
        switch state {
        case .unknown:
            EmptyView()
        case .upToDate:
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .imageScale(.small)
                .accessibilityLabel("Up to date")
        case .hasUpdate:
            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(Color.accentColor)
                .imageScale(.small)
                .accessibilityLabel("Update available")
        case .error(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .imageScale(.small)
                .accessibilityLabel("Update check failed: \(message)")
        }
    }
}

struct PullImageView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let environmentID: EnvironmentID
    let onComplete: () async -> Void

    @State private var imageName = ""
    @State private var isPulling = false
    @State private var didComplete = false
    @State private var statusLine = ""
    @State private var layerOrder: [String] = []
    @State private var layers: [String: PullProgressEvent] = [:]
    @State private var errorMessage: String?
    @State private var pullTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section("Pull Image") {
                        FormTextField(
                            title: "Image",
                            placeholder: "nginx:latest",
                            text: $imageName,
                            autocapitalization: .never,
                            autocorrectionDisabled: true,
                            helper: "Include a tag when you do not want Docker to assume latest.",
                            disabled: isPulling || didComplete
                        )
                    }

                    if !statusLine.isEmpty {
                        Section("Status") {
                            Label(statusLine, systemImage: didComplete ? "checkmark.circle.fill" : "arrow.down.circle")
                                .foregroundStyle(didComplete ? .green : .primary)
                                .font(.subheadline)
                        }
                    }

                    if let error = errorMessage {
                        Section {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                        }
                    }
                }
                .frame(maxHeight: 280)

                if !layerOrder.isEmpty {
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(layerOrder, id: \.self) { layerID in
                                    if let event = layers[layerID] {
                                        layerRow(event)
                                            .id(layerID)
                                    }
                                }
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onChange(of: layerOrder.count) { _, _ in
                            if let last = layerOrder.last {
                                withAnimation(.none) { proxy.scrollTo(last, anchor: .bottom) }
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .navigationTitle("Pull Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !didComplete {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(isPulling ? "Stop" : "Cancel") {
                            if isPulling {
                                pullTask?.cancel()
                            } else {
                                dismiss()
                            }
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if didComplete {
                        Button("Done") { dismiss() }
                    } else {
                        Button(action: pullImage) {
                            if isPulling { ProgressView().scaleEffect(0.8) }
                            else { Text("Pull") }
                        }
                        .disabled(imageName.isEmpty || isPulling)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func layerRow(_ event: PullProgressEvent) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(event.id ?? "")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(event.status ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let detail = event.progressDetail,
               let total = detail.total, total > 0,
               let current = detail.current {
                ProgressView(value: Double(min(current, total)), total: Double(total))
                    .tint(progressTint(for: event.status))
            } else if event.status?.lowercased().contains("complete") == true ||
                      event.status?.lowercased().contains("exists") == true {
                ProgressView(value: 1, total: 1).tint(.green)
            }
        }
    }

    private func progressTint(for status: String?) -> Color {
        let s = status?.lowercased() ?? ""
        if s.contains("download") { return .blue }
        if s.contains("extract") { return .orange }
        if s.contains("complete") || s.contains("pull complete") { return .green }
        return Color.accentColor
    }

    private func pullImage() {
        guard let client = manager.client else { return }
        let (image, tag) = parseImageNameAndTag(imageName)
        let options = ImagePullOptions(imageName: image, tag: tag)

        isPulling = true
        didComplete = false
        statusLine = "Connecting…"
        layerOrder = []
        layers = [:]
        errorMessage = nil

        pullTask = Task {
            defer { isPulling = false; pullTask = nil }
            do {
                let stream = try client.images.pullStream(envID: environmentID, options: options)
                for try await event in stream {
                    if Task.isCancelled { break }
                    apply(event)
                }
                if !Task.isCancelled, errorMessage == nil {
                    didComplete = true
                    statusLine = "Pull complete"
                    if let cached = manager.cached {
                        await cached.invalidate(envID: environmentID, paths: [
                            client.rest.environmentPath(environmentID, "images") + "*",
                            client.rest.environmentPath(environmentID, "images/*")
                        ])
                    }
                    mutationStore.markChanged(kind: .images, envID: environmentID)
                    await onComplete()
                }
            } catch is CancellationError {
                statusLine = "Cancelled"
            } catch {
                errorMessage = friendlyErrorMessage(error)
                statusLine = ""
            }
        }
    }

    private func apply(_ event: PullProgressEvent) {
        if let err = event.error, !err.isEmpty {
            errorMessage = err
            return
        }
        if let id = event.id, !id.isEmpty {
            if layers[id] == nil { layerOrder.append(id) }
            layers[id] = event
        } else if let status = event.status, !status.isEmpty {
            statusLine = status
        }
        // The SDK's `PullProgressEvent` doesn't expose an explicit phase, so
        // detect the terminal status string. "Pull complete" is emitted per-layer;
        // the overall terminal messages are "Status: Downloaded newer image..." /
        // "Status: Image is up to date...".
        if let status = event.status {
            let lower = status.lowercased()
            if lower.hasPrefix("status: ") || lower == "pull complete" {
                statusLine = lower == "pull complete" ? "Pull complete" : status
            }
        }
    }

    private func parseImageNameAndTag(_ raw: String) -> (String, String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip an optional digest (`@sha256:...`) before splitting on `:`.
        let beforeDigest = trimmed.split(separator: "@", maxSplits: 1).first.map(String.init) ?? trimmed
        // Find the last ':' that isn't part of the registry host:port (heuristic: tag has no '/').
        if let colonIdx = beforeDigest.lastIndex(of: ":"),
           !beforeDigest[colonIdx...].contains("/") {
            let name = String(beforeDigest[..<colonIdx])
            let tag = String(beforeDigest[beforeDigest.index(after: colonIdx)...])
            return (name, tag.isEmpty ? nil : tag)
        }
        return (beforeDigest, nil)
    }
}
