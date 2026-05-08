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
    @State private var showPullSheet = false
    @State private var showPruneConfirm = false
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
                ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if images.isEmpty {
                ContentUnavailableView("No Images", systemImage: "photo.stack", description: Text("No images found"))
            } else {
                List {
                    ResourceSearchControls(
                        searchText: $searchText,
                        sortOrder: $sortOrder,
                        prompt: "Search images",
                        filterActive: activeFilterCount > 0
                    ) {
                        showFilterSheet = true
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)

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
        .toolbar {
            if isAdmin {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(destination: ContainerRegistriesView()) {
                        Image(systemName: "shippingbox")
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { Task { await loadImages(reset: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showPullSheet = true } label: {
                    Image(systemName: "arrow.down.circle")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showPruneConfirm = true } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .alert("Prune Unused Images", isPresented: $showPruneConfirm) {
            Button("Prune", role: .destructive) { Task { await pruneImages() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove all unused and dangling images. This cannot be undone.")
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
    }

    private func imageLink(_ image: ImageInfo) -> some View {
        NavigationLink(destination: ImageDetailView(image: image, environmentID: environmentID)) {
            ImageRow(image: image)
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
        if reset { currentPage = 1; images = [] }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let path = client.rest.environmentPath(environmentID, "images")
            let query = [URLQueryItem(name: "page", value: "\(currentPage)"),
                         URLQueryItem(name: "pageSize", value: "50")]
            let newImages: [ImageInfo] = try await client.rest.get(path, query: query)
            images.append(contentsOf: newImages)
            hasMore = newImages.count == 50
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMore() async {
        currentPage += 1
        await loadImages(reset: false)
    }

    private func pruneImages() async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "images/prune")
            let _: DataResponse<String> = try await client.rest.post(path, body: String?.none)
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

struct ImageRow: View {
    let image: ImageInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.stack.fill")
                .font(.title3)
                .foregroundStyle(.purple)
                .frame(width: 36, height: 36)
                .glassEffect(.regular, in: .circle)

            VStack(alignment: .leading, spacing: 3) {
                Text(image.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(String(image.id.prefix(12)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(image.size.byteString)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct PullImageView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let environmentID: EnvironmentID
    let onComplete: () async -> Void

    @State private var imageName = ""
    @State private var isPulling = false
    @State private var pullOutput: [String] = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section("Pull Image") {
                        TextField("e.g. nginx:latest", text: $imageName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    if let error = errorMessage {
                        Section {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                        }
                    }
                }
                .frame(height: 180)

                if !pullOutput.isEmpty {
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(pullOutput.enumerated()), id: \.offset) { index, line in
                                    Text(line)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .id(index)
                                }
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onChange(of: pullOutput.count) { _, count in
                            proxy.scrollTo(count - 1)
                        }
                    }
                }

                Spacer()
            }
            .navigationTitle("Pull Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: pullImage) {
                        if isPulling { ProgressView().scaleEffect(0.8) }
                        else { Text("Pull") }
                    }
                    .disabled(imageName.isEmpty || isPulling)
                }
            }
        }
    }

    private func pullImage() {
        guard let client = manager.client else { return }
        isPulling = true
        pullOutput = []
        errorMessage = nil
        Task {
            do {
                let path = client.rest.environmentPath(environmentID, "images/pull")
                let body = ["image": imageName]
                let _: DataResponse<String> = try await client.rest.post(path, body: body)
                pullOutput.append("Done.")
                await onComplete()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isPulling = false
        }
    }
}
