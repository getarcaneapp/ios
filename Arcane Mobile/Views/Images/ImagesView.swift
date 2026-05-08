import SwiftUI
import Arcane

struct ImagesView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let environmentID: EnvironmentID
    let environmentName: String

    @State private var images: [ImageInfo] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var updateInfo: [String: ImageUpdateResponse] = [:]
    @State private var showPullSheet = false
    @State private var showPruneConfirm = false
    @State private var showPruneSheet = false
    @State private var showUploadSheet = false
    @State private var currentPage = 1
    @State private var hasMore = false
    @State private var totalPages: Int64 = 1
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

    private var isAdmin: Bool {
        manager.currentUser?.isAdmin == true
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
                    if !usedImages.isEmpty {
                        Section("Used") {
                            ForEach(usedImages) { image in
                                imageLink(image)
                            }
                        }
                    }

                    if !unusedImages.isEmpty {
                        Section("Unused") {
                            ForEach(unusedImages) { image in
                                imageLink(image)
                            }
                        }
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
                        Image(systemName: "shippingbox")
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
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showPullSheet = true } label: {
                    Image(systemName: "arrow.down.circle")
                }
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
            }
        }
        .alert("Prune Dangling Images", isPresented: $showPruneConfirm) {
            Button("Prune", role: .destructive) { Task { await pruneImages() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove all dangling images. This cannot be undone.")
        }
        .sheet(isPresented: $showPruneSheet) {
            ImagePruneView(environmentID: environmentID) {
                await loadImages(reset: true)
            }
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
        .refreshable { await loadImages(reset: true) }
        .sheet(isPresented: $showPullSheet) {
            PullImageView(environmentID: environmentID) {
                await loadImages(reset: true)
            }
        }
        .sheet(isPresented: $showUploadSheet) {
            UploadImageView(environmentID: environmentID) {
                await loadImages(reset: true)
            }
        }
    }

    private func imageLink(_ image: ImageInfo) -> some View {
        NavigationLink(destination: ImageDetailView(image: image, environmentID: environmentID)) {
            ImageRow(image: image, updateState: updateState(for: image))
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await removeImage(image) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func loadImages(reset: Bool) async {
        guard let client = manager.client else { return }
        if reset { currentPage = 1 }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let path = client.rest.environmentPath(environmentID, "images")
            let query = [URLQueryItem(name: "page", value: "\(currentPage)"),
                         URLQueryItem(name: "pageSize", value: "50")]
            let newImages: [ImageInfo] = try await client.rest.get(path, query: query)
            if reset {
                images = newImages
            } else {
                images.append(contentsOf: newImages)
            }
            hasMore = newImages.count == 50
            await loadUpdateInfo(for: newImages)
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
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
        currentPage += 1
        await loadImages(reset: false)
    }

    private func pruneImages() async {
        guard let client = manager.client else { return }
        let body = ImagePruneRequest(mode: "dangling", until: nil, dangling: nil, filters: nil)
        do {
            let path = client.rest.environmentPath(environmentID, "images/prune")
            let _: ImagePruneReport = try await client.rest.post(path, body: body)
            await loadImages(reset: true)
        } catch {}
    }

    private func removeImage(_ image: ImageInfo) async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "images/\(image.id)")
            let _: DataResponse<String> = try await client.rest.delete(path)
            images.removeAll { $0.id == image.id }
        } catch {}
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
                .foregroundStyle(.blue)
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
                            LazyVStack(alignment: .leading, spacing: 6) {
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
                                proxy.scrollTo(last, anchor: .bottom)
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
        return .accentColor
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
