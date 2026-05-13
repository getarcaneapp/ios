import SwiftUI
import Arcane

struct ImagesView: View {
    private static let pageSize = 50

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    let environmentID: EnvironmentID
    let environmentName: String

    @State private var images: [ImageInfo] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var actionErrorMessage: String?
    @State private var searchText = ""
    @State private var updateInfo: [String: ImageUpdateResponse] = [:]
    @State private var showPullSheet = false
    @State private var showPruneConfirm = false
    @State private var showPruneSheet = false
    @State private var showUploadSheet = false
    @State private var currentPage = 1
    @State private var hasMore = false
    @State private var loadGeneration = 0
    @State private var showFilterSheet = false
    @State private var tagsFilter = ImageTagsFilter.all
    @State private var sortOrder = ListSortOrder.ascending

    private enum ImageTagsFilter: String, CaseIterable {
        case all = "All", tagged = "Tagged", untagged = "Untagged"
    }

    private var activeFilterCount: Int { tagsFilter != .all ? 1 : 0 }

    private var filtered: [ImageInfo] {
        images.filter { image in
            let matchesSearch = searchText.isEmpty ||
                image.displayName.localizedCaseInsensitiveContains(searchText) ||
                image.id.localizedCaseInsensitiveContains(searchText)
            let isTagged = image.repoTags?.contains(where: { $0 != "<none>:<none>" }) ?? false
            let matchesTags = tagsFilter == .all
                || (tagsFilter == .tagged && isTagged)
                || (tagsFilter == .untagged && !isTagged)
            return matchesSearch && matchesTags
        }
        .sorted {
            sortOrder.areInIncreasingOrder($0.displayName, $1.displayName)
        }
    }

    private var usedImages: [ImageInfo] {
        filtered.filter(\.inUse)
    }

    private var unusedImages: [ImageInfo] {
        filtered.filter { !$0.inUse }
    }

    private var listSections: [StableListSection<String, ImageInfo>] {
        [
            .init(id: "used", title: "Used", items: usedImages),
            .init(id: "unused", title: "Unused", items: unusedImages)
        ]
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
                ProgressView("Loading images...").frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    Text("No images found")
                } actions: {
                    Button("Reload") { Task { await loadImages(reset: true) } }
                }
            } else {
                List {
                    StableSectionedList(listSections) { image in
                        imageLink(image)
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
            "Couldn't Delete Image",
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
        .sheet(isPresented: $showPullSheet) {
            PullImageView(environmentID: environmentID) {}
        }
        .sheet(isPresented: $showUploadSheet) {
            UploadImageView(environmentID: environmentID) {}
        }
        .onChange(of: mutationVersion) { _, _ in
            Task { await loadImages(reset: true, refresh: true) }
        }
    }

    private func imageLink(_ image: ImageInfo) -> some View {
        let state = updateState(for: image)
        return NavigationLink(destination: ImageDetailView(image: image, environmentID: environmentID)) {
            ImageRow(image: image, updateState: state)
        }
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

    private func imagePreview(_ image: ImageInfo, state: ImageUpdateState) -> some View {
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
            let response: ImageListPage?
            if reset, let cached = manager.cached {
                let path = client.rest.environmentPath(environmentID, "images")
                let cachePath = "\(path)?start=0&limit=\(Self.pageSize)"
                let fetcher: @Sendable () async throws -> ImageListPage = {
                    try await client.listImagesPage(
                        envID: environmentID,
                        start: 0,
                        limit: Self.pageSize
                    )
                }
                response = try await cached.getCustom(
                    path: cachePath,
                    as: ImageListPage.self,
                    policy: .imagesList,
                    envID: environmentID,
                    refresh: refresh,
                    onFresh: { fresh in
                        applyImagesPage(fresh, reset: true, generation: generation)
                        Task { await loadUpdateInfo(for: fresh.data) }
                    },
                    fetcher: fetcher
                )
            } else {
                response = try await client.listImagesPage(
                    envID: environmentID,
                    start: start,
                    limit: Self.pageSize
                )
            }

            guard let response else {
                guard loadGeneration == generation else { return }
                if reset {
                    images = []
                    currentPage = 1
                    hasMore = false
                }
                return
            }
            applyImagesPage(response, reset: reset, generation: generation)
            await loadUpdateInfo(for: response.data)
        } catch {
            guard loadGeneration == generation else { return }
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func applyImagesPage(_ response: ImageListPage, reset: Bool, generation: Int) {
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
    }

    private func invalidateImageCaches() async {
        guard let cached = manager.cached, let client = manager.client else { return }
        await cached.invalidate(envID: environmentID, paths: [
            client.rest.environmentPath(environmentID, "images") + "*",
            client.rest.environmentPath(environmentID, "images/*")
        ])
    }

    private func loadUpdateInfo(for newImages: [ImageInfo]) async {
        guard let client = manager.client else { return }
        let refs = newImages
            .flatMap { $0.repoTags ?? [] }
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

    private func updateState(for image: ImageInfo) -> ImageUpdateState {
        guard let tags = image.repoTags else { return .unknown }
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
        guard hasMore else { return }
        await loadImages(reset: false)
    }

    private func pruneImages() async {
        guard let client = manager.client else { return }
        let body = ImagePruneRequest(mode: "dangling", until: nil, dangling: nil, filters: nil)
        do {
            let path = client.rest.environmentPath(environmentID, "images/prune")
            let _: ImagePruneReport = try await client.rest.post(path, body: body)
            await invalidateImageCaches()
            mutationStore.markChanged(kind: .images, envID: environmentID)
        } catch {}
    }

    private func removeImage(_ image: ImageInfo) async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "images/\(image.id)")
            let _: DataResponse<String> = try await client.rest.delete(path)
            withAnimation {
                images.removeAll { $0.id == image.id }
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
    let image: ImageInfo
    var updateState: ImageUpdateState = .unknown

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.stack.fill")
                .font(.title3)
                .foregroundStyle(.purple)
                .frame(width: 36, height: 36)
                .glassEffect(.regular, in: .circle)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(image.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    UpdateStateBadge(state: updateState)
                }
                Text(image.size.byteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                        TextField("e.g. nginx:latest", text: $imageName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(isPulling || didComplete)
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
                ToolbarItem(placement: .cancellationAction) {
                    Button(isPulling ? "Stop" : "Cancel") {
                        if isPulling {
                            pullTask?.cancel()
                        } else {
                            dismiss()
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
        guard let serverURL = URL(string: manager.serverURL) else {
            errorMessage = "Invalid server URL"
            return
        }
        let (image, tag) = parseImageNameAndTag(imageName)
        let request = PullImageRequest(imageName: image, tag: tag)

        isPulling = true
        didComplete = false
        statusLine = "Connecting…"
        layerOrder = []
        layers = [:]
        errorMessage = nil

        pullTask = Task {
            defer { isPulling = false; pullTask = nil }
            do {
                let body = try JSONEncoder().encode(request)
                let path = client.rest.environmentPath(environmentID, "images/pull")
                let stream = try await NDJSONStream.stream(
                    PullProgressEvent.self,
                    client: client,
                    serverURL: serverURL,
                    path: path,
                    method: "POST",
                    body: body
                )
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
        if event.phase?.lowercased() == "complete" {
            statusLine = "Pull complete"
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
