import SwiftUI
import Arcane

struct ImagePatchTargetsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let environmentID: EnvironmentID
    @State private var loadMoreError: String?
    @State private var targets: [ImagePatchTarget] = []
    @State private var search = ""
    @State private var error: String?
    @State private var loading = false
    @State private var hasMore = false
    @State private var requestGeneration = 0
    private var scope: String { "\(manager.serverURL)|\(manager.clientGeneration)|\(environmentID.rawValue)|\(search)" }
    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.secondary) }
            ForEach(targets) { target in
                NavigationLink {
                    ImagePatchView(environmentID: environmentID, imageID: target.imageId,
                        imageName: target.imageRef, localOnly: target.localOnly == true)
                } label: {
                    VStack(alignment: .leading) {
                        Text(target.imageRef)
                        Text("\(String(target.fixableCount)) fixable · \(String(target.totalCount)) total")
                            .font(.caption).foregroundStyle(.secondary)
                        if target.localOnly == true { Text("Local image cannot be patched").font(.caption) }
                        if let patch = target.lastPatch {
                            Text("Last patch: \(patch.status)").font(.caption)
                        }
                    }
                }
            }
            if loading { ProgressView() }
            PaginatedListFooter(
                hasMore: hasMore, loadMoreError: loadMoreError,
                onRetry: { Task { await load(reset: false) } },
                onLoadMore: { Task { await load(reset: false) } }
            )
            if targets.isEmpty && !loading && error == nil {
                ContentUnavailableView("No patch targets", systemImage: "shield")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Patch Images")
        .searchable(text: $search)
        .task(id: scope) {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            await load(reset: true)
        }
        .refreshable { await load(reset: true) }
    }
    private func load(reset: Bool) async {
        guard let client = manager.client else { return }
        if loading && !reset { return }
        requestGeneration &+= 1
        let generation = requestGeneration
        let expected = scope
        loading = true; error = nil
        loadMoreError = nil
        defer { if expected == scope, generation == requestGeneration { loading = false } }
        do {
            let result = try await client.images.patchTargets(envID: environmentID,
                query: .init(search: search.isEmpty ? nil : search, start: reset ? 0 : targets.count, limit: 30))
            guard !Task.isCancelled, expected == scope, generation == requestGeneration else { return }
            targets = reset ? result.data : targets + result.data; hasMore = result.data.count == 30
        } catch is CancellationError { }
        catch ArcaneError.notFound { if expected == scope { error = "Image patching is not available on this server." } }
        catch { if expected == scope { if reset { self.error = friendlyErrorMessage(error) } else { loadMoreError = friendlyErrorMessage(error) } } }
    }
}

struct ImagePatchView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutations
    let environmentID: EnvironmentID
    let imageID: String
    let imageName: String
    var localOnly = false
    @State private var suffix = ""
    @State private var patchedTag = ""
    @State private var scanID = ""
    @State private var timeout = ""
    @State private var ignoreErrors = false
    @State private var record: ImagePatchRecord?
    @State private var activity: Activity?
    @State private var submitting = false
    @State private var patchTask: Task<Void, Never>?
    @State private var available = false
    @State private var availabilityError: String?
    @State private var refreshToken = UUID()
    private var scope: String { "\(manager.serverURL)|\(manager.clientGeneration)|\(environmentID.rawValue)|\(imageID)" }
    private var canPatch: Bool { available && !localOnly && manager.permissions.has("images:patch", in: environmentID) }

    var body: some View {
        Form {
            Section("Source image") { Text(imageName).textSelection(.enabled) }
            if let availabilityError { Text(availabilityError).foregroundStyle(.secondary) }
            if localOnly { Text("Images without a registry source cannot be patched.").foregroundStyle(.secondary) }
            if let record {
                Section("Patch result") {
                    LabeledContent("Status", value: record.status)
                    LabeledContent("Patched image", value: record.patchedRef)
                    if let error = record.error { Text(error).foregroundStyle(.red) }
                    if let count = record.packagesUpdated { LabeledContent("Packages updated", value: String(count)) }
                    if let activity { NavigationLink("Progress and output") { ActivityDetailView(activity: activity) } }
                    if record.status == "patching" { ProgressView("Patching packages") }
                    Button("Refresh status") { refreshToken = UUID() }
                    Text("Deploy the patched image separately after reviewing the result.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("Patched image") {
                    TextField("Tag suffix (server default when empty)", text: $suffix)
                    TextField("Explicit patched tag", text: $patchedTag)
                    TextField("Scan ID (empty updates all packages)", text: $scanID)
                    TextField("Timeout in seconds (server default)", text: $timeout).keyboardType(.numberPad)
                    Toggle("Continue after package errors", isOn: $ignoreErrors)
                    Button("Patch image") { patchTask = Task { await start() } }.disabled(!canPatch || submitting)
                    if submitting { ProgressView() }
                }
            }
        }
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .navigationTitle("Patch Image")
        .onChange(of: manager.clientGeneration) { patchTask?.cancel(); record = nil; activity = nil }
        .onChange(of: manager.activeEnvironmentID) { patchTask?.cancel(); record = nil; activity = nil }
        .onDisappear { patchTask?.cancel() }
        .task(id: scope) { await checkAvailability() }
        .task(id: "\(scope)|\(record?.id ?? "")|\(refreshToken)") { await follow() }
    }

    private func checkAvailability() async {
        available = false; record = nil; activity = nil; availabilityError = nil
        guard let client = manager.client else { return }
        do {
            _ = try await client.images.patchTargets(envID: environmentID, query: .init(limit: 1))
            guard !Task.isCancelled else { return }
            available = true
        } catch is CancellationError { }
        catch ArcaneError.notFound { availabilityError = "Image patching is not available on this server." }
        catch { availabilityError = error.localizedDescription }
    }

    private func start() async {
        guard canPatch, let client = manager.client else { return }
        let expected = scope
        let trimmedTimeout = timeout.trimmingCharacters(in: .whitespacesAndNewlines)
        let seconds = Int(trimmedTimeout)
        guard trimmedTimeout.isEmpty || (seconds ?? 0) > 0 else {
            showToast(.error("Enter a positive timeout in seconds.")); return
        }
        submitting = true
        defer { submitting = false }
        do {
            let result = try await client.images.patch(envID: environmentID, imageID: imageID,
                options: .init(suffix: suffix.isEmpty ? nil : suffix,
                    patchedTag: patchedTag.isEmpty ? nil : patchedTag,
                    timeoutSeconds: seconds, scanId: scanID.isEmpty ? nil : scanID, ignoreErrors: ignoreErrors))
            guard !Task.isCancelled, expected == scope else { return }
            record = result
            showToast(.info("Image patch started"))
        } catch { showToast(.error(error.localizedDescription)) }
    }

    private func follow() async {
        guard let current = record, let client = manager.client else { return }
        do {
            repeat {
                if let id = current.activityId, manager.permissions.has("activities:read", in: environmentID) {
                    let detail = try await client.activities.detail(envID: environmentID, activityID: id)
                    guard !Task.isCancelled else { return }
                    activity = detail.activity
                }
                let updated: ImagePatchRecord?
                if manager.permissions.has("images:list", in: environmentID) {
                    let page = try await client.images.listPatches(envID: environmentID,
                        query: .init(search: current.originalRef, limit: 100))
                    updated = page.data.first(where: { $0.id == current.id })
                } else {
                    let targets = try await client.images.patchTargets(envID: environmentID,
                        query: .init(search: current.originalRef, limit: 100))
                    updated = targets.data.compactMap(\.lastPatch).first(where: { $0.id == current.id })
                }
                guard !Task.isCancelled else { return }
                if let updated {
                    record = updated
                    if updated.status != "patching" {
                        if updated.status == "completed" { mutations.markChanged(kind: .images, envID: environmentID) }
                        return
                    }
                }
                try await Task.sleep(for: .seconds(3))
            } while !Task.isCancelled
        } catch is CancellationError { }
        catch { showToast(.error("Status refresh failed: \(error.localizedDescription)")) }
    }
}
