import SwiftUI
import Arcane

struct AllEnvironmentsImageUpdatesView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager

    @State private var buckets: [EnvUpdateBucket] = []
    @State private var isLoading = false
    @State private var hasLoadedOnce = false
    @State private var checkingRef: String?
    @State private var rescanningEnvID: String?

    private static let maxConcurrentEnvs = 4
    private static let imagesPageSize: Int = 500

    var body: some View {
        Group {
            if !hasLoadedOnce && isLoading {
                ProgressView("Loading updates…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hasLoadedOnce && buckets.isEmpty {
                ContentUnavailableView(
                    "No Environments",
                    systemImage: "bolt.slash",
                    description: Text("Add an environment to see image updates.")
                )
            } else {
                List {
                    ForEach(buckets) { bucket in
                        section(for: bucket)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Updates")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadAll() }
        .refreshable { await loadAll(refresh: true) }
    }

    // MARK: - Sections

    @ViewBuilder
    private func section(for bucket: EnvUpdateBucket) -> some View {
        Section {
            ImageUpdateSummaryStrip(summary: bucket.summary, isLoading: bucket.loading)

            if let error = bucket.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            let taggedSet = Set(bucket.taggedRefs)
            let taggedWithUpdates = bucket.taggedRefs.filter { bucket.byRef[$0]?.hasUpdate == true }
            let untaggedWithUpdates = bucket.byRef
                .compactMap { $0.value.hasUpdate && !taggedSet.contains($0.key) ? $0.key : nil }
                .sorted()
            updateRows(for: bucket, refs: taggedWithUpdates + untaggedWithUpdates)

            imageCountFooter(for: bucket)
            recheckAllButton(for: bucket)
        } header: {
            HStack {
                Text(bucket.env.displayName)
                Spacer()
                StatusBadge(status: bucket.env.status)
            }
        }
    }

    @ViewBuilder
    private func updateRows(for bucket: EnvUpdateBucket, refs: [String]) -> some View {
        if !refs.isEmpty {
            ForEach(refs, id: \.self) { ref in
                UpdateRow(
                    ref: ref,
                    info: bucket.byRef[ref],
                    isChecking: checkingRef == bucket.bucketKey(for: ref),
                    recheck: { Task { await recheck(bucket: bucket, ref: ref) } }
                )
            }
        } else if let summary = bucket.summary, summary.imagesWithUpdates > 0, !bucket.loading {
            Text(
                """
                Update details unavailable for \(summary.imagesWithUpdates) \
                image\(summary.imagesWithUpdates == 1 ? "" : "s").
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if bucket.summary != nil && !bucket.loading {
            Text("All up to date")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private func imageCountFooter(for bucket: EnvUpdateBucket) -> some View {
        if bucket.totalImages > bucket.taggedRefs.count && bucket.taggedRefs.count > 0 {
            Text("Showing \(bucket.taggedRefs.count) of \(bucket.totalImages) images")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func recheckAllButton(for bucket: EnvUpdateBucket) -> some View {
        Button {
            Task { await recheckAll(bucket: bucket) }
        } label: {
            HStack {
                if rescanningEnvID == bucket.id {
                    ProgressView().scaleEffect(0.8)
                    Text("Rechecking…")
                } else {
                    Image(systemName: "arrow.clockwise")
                    Text("Recheck all images")
                }
                Spacer()
            }
            .font(.subheadline)
        }
        .disabled(rescanningEnvID != nil || bucket.loading)
    }

    // MARK: - Data loading

    private func loadAll(refresh: Bool = false) async {
        guard let cached = manager.cached, let client = manager.client else { return }
        if !hasLoadedOnce { isLoading = true }
        defer {
            isLoading = false
            hasLoadedOnce = true
        }

        let envs: [Arcane.Environment] = (try? await cached.getListGlobal(
            "environments", elementType: Arcane.Environment.self,
            policy: .environments, refresh: refresh,
            onFresh: { _ in }
        )) ?? []

        if Task.isCancelled { return }

        buckets = envs.map { EnvUpdateBucket(env: $0, loading: true) }
        guard !envs.isEmpty else { return }

        let pageSize = Self.imagesPageSize

        await withTaskGroup(of: EnvLoadResult.self) { group in
            var iterator = envs.enumerated().makeIterator()
            let initial = min(Self.maxConcurrentEnvs, envs.count)
            for _ in 0..<initial {
                guard let (index, env) = iterator.next() else { break }
                let envID = EnvironmentID(rawValue: env.id)
                group.addTask {
                    await Self.fetchEnv(index: index, envID: envID, client: client, pageSize: pageSize)
                }
            }
            for await result in group {
                if Task.isCancelled { return }
                apply(result: result)
                if let (index, env) = iterator.next() {
                    let envID = EnvironmentID(rawValue: env.id)
                    group.addTask {
                        await Self.fetchEnv(index: index, envID: envID, client: client, pageSize: pageSize)
                    }
                }
            }
        }
    }

    private func apply(result: EnvLoadResult) {
        guard buckets.indices.contains(result.index) else { return }
        var bucket = buckets[result.index]
        bucket.summary = result.summary
        bucket.byRef = result.byRef
        bucket.taggedRefs = result.taggedRefs
        bucket.totalImages = result.totalImages
        bucket.error = result.error
        bucket.loading = false
        buckets[result.index] = bucket
    }

    private nonisolated static func fetchEnv(
        index: Int, envID: EnvironmentID, client: ArcaneClient, pageSize: Int
    ) async -> EnvLoadResult {
        let summaryPath = client.rest.environmentPath(envID, "image-updates/summary")
        let summary: ImageUpdateSummary? = try? await client.rest.get(summaryPath)

        let images: [ImageSummary]
        let totalImages: Int
        let listError: String?
        do {
            let query = SearchPaginationSort(start: 0, limit: pageSize)
            let response = try await client.images.list(envID: envID, query: query)
            images = response.data
            totalImages = Int(response.pagination.totalItems)
            listError = nil
        } catch {
            images = []
            totalImages = 0
            listError = (error as? ArcaneError)?.localizedDescription ?? error.localizedDescription
        }

        let refs = images.flatMap { $0.repoTags }.filter { $0 != "<none>:<none>" }

        // Seed byRef from each image's inline updateInfo (server-populated on
        // the list endpoint). This decouples per-row update state from the
        // separate by-refs cache, which can return inconsistent keys or stale
        // data per environment. Only seed entries where the server has a
        // definitive answer — avoid claiming "up to date" for images that
        // simply haven't been checked yet.
        var byRef: BatchImageUpdateResponse = [:]
        for image in images {
            guard let info = image.updateInfo, info.isDefinitive else { continue }
            let response = info.asResponse
            for tag in image.repoTags where tag != "<none>:<none>" {
                byRef[tag] = response
            }
        }

        // Merge with the by-refs API. Its keys take precedence when present —
        // it has the freshest cached check results.
        if !refs.isEmpty {
            let byRefPath = client.rest.environmentPath(envID, "image-updates/by-refs")
            let query = [URLQueryItem(name: "imageRefs", value: refs.joined(separator: ","))]
            if let map: BatchImageUpdateResponse = try? await client.rest.get(byRefPath, query: query) {
                byRef.merge(map) { _, new in new }
            }
        }

        // Only surface an error if we couldn't get either summary or images.
        let error: String? = (summary == nil && listError != nil) ? listError : nil

        return EnvLoadResult(
            index: index,
            summary: summary,
            byRef: byRef,
            taggedRefs: refs,
            totalImages: totalImages,
            error: error
        )
    }

    private func recheckAll(bucket: EnvUpdateBucket) async {
        guard let client = manager.client else { return }
        rescanningEnvID = bucket.id
        defer { rescanningEnvID = nil }

        let envID = EnvironmentID(rawValue: bucket.env.id)
        let checkPath = client.rest.environmentPath(envID, "image-updates/check-all")
        let body: [String: String] = [:]

        // Local envs return BatchImageUpdateResponse synchronously; remote envs
        // sometimes throw on decode (different response shape). Try the typed
        // post first — if it succeeds, populate byRef immediately — then
        // unconditionally refetch the env state so remote envs still update.
        let postedMap: BatchImageUpdateResponse? =
            try? await client.rest.post(checkPath, body: body)

        guard let idx = buckets.firstIndex(where: { $0.id == bucket.id }) else { return }

        if let map = postedMap {
            buckets[idx].byRef = map
            buckets[idx].taggedRefs = Array(map.keys)
        }

        let result = await Self.fetchEnv(
            index: idx, envID: envID, client: client, pageSize: Self.imagesPageSize
        )

        // If the post returned a richer map than the by-refs cache, keep the
        // post result. Otherwise apply the full refetch.
        guard let idx2 = buckets.firstIndex(where: { $0.id == bucket.id }) else { return }
        let postedHasMore = (postedMap?.count ?? 0) > result.byRef.count
        if postedHasMore, let map = postedMap {
            buckets[idx2].summary = result.summary ?? buckets[idx2].summary
            buckets[idx2].totalImages = result.totalImages
            buckets[idx2].error = result.error
            buckets[idx2].loading = false
            buckets[idx2].byRef = map
            buckets[idx2].taggedRefs = Array(map.keys)
        } else {
            apply(result: result)
        }
    }

    private func recheck(bucket: EnvUpdateBucket, ref: String) async {
        guard let client = manager.client else { return }
        let key = bucket.bucketKey(for: ref)
        checkingRef = key
        defer { checkingRef = nil }
        let envID = EnvironmentID(rawValue: bucket.env.id)
        let path = client.rest.environmentPath(envID, "image-updates/check")
        let query = [URLQueryItem(name: "imageRef", value: ref)]
        if let response: ImageUpdateResponse = try? await client.rest.get(path, query: query) {
            guard let idx = buckets.firstIndex(where: { $0.id == bucket.id }) else { return }
            buckets[idx].byRef[ref] = response
        }
    }
}

// MARK: - Bucket

struct EnvUpdateBucket: Identifiable {
    let env: Arcane.Environment
    var summary: ImageUpdateSummary?
    var byRef: BatchImageUpdateResponse = [:]
    var taggedRefs: [String] = []
    var totalImages: Int = 0
    var loading: Bool = false
    var error: String?

    var id: String { env.id }

    func bucketKey(for ref: String) -> String { "\(env.id)::\(ref)" }
}

private struct EnvLoadResult: Sendable {
    let index: Int
    let summary: ImageUpdateSummary?
    let byRef: BatchImageUpdateResponse
    let taggedRefs: [String]
    let totalImages: Int
    let error: String?
}

private extension Arcane.ImageUpdateInfo {
    /// True when the server's inline updateInfo carries an actual check
    /// result — not just struct defaults. Used to avoid claiming "up to
    /// date" for images that simply haven't been scanned yet.
    nonisolated var isDefinitive: Bool {
        hasUpdate
            || !error.isEmpty
            || !currentVersion.isEmpty
            || !currentDigest.isEmpty
            || !latestDigest.isEmpty
    }

    /// Bridge into the mobile-side `ImageUpdateResponse` used by `UpdateRow`
    /// and the rest of this view.
    nonisolated var asResponse: ImageUpdateResponse {
        ImageUpdateResponse(
            hasUpdate: hasUpdate,
            updateType: updateType.isEmpty ? nil : updateType,
            currentVersion: currentVersion.isEmpty ? nil : currentVersion,
            latestVersion: latestVersion.isEmpty ? nil : latestVersion,
            currentDigest: currentDigest.isEmpty ? nil : currentDigest,
            latestDigest: latestDigest.isEmpty ? nil : latestDigest,
            checkTime: nil,
            responseTimeMs: responseTimeMs == 0 ? nil : responseTimeMs,
            error: error.isEmpty ? nil : error,
            authMethod: authMethod,
            authUsername: authUsername,
            authRegistry: authRegistry,
            usedCredential: usedCredential
        )
    }
}
