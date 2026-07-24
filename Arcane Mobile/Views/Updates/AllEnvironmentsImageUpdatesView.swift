import SwiftUI
import Arcane

/// The Updates page: a card-based, cross-environment view of pending image
/// updates. Rows stay minimal — name, what changed, one-tap update icon —
/// and tapping a row opens a detail sheet with the full untruncated ref,
/// version/digest info, and per-container / per-project update actions.
struct AllEnvironmentsImageUpdatesView: View {
    /// True when this page is presented as a sheet (dashboard): starting an
    /// update dismisses the sheet so the root pill becomes the progress
    /// surface. The pill belongs above the tab bar, not floating in a sheet.
    var dismissOnOperationStart: Bool = false

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(ImageUpdateCountStore.self) private var imageUpdateCountStore
    @SwiftUI.Environment(\.dismiss) private var dismiss

    @State private var buckets: [EnvUpdateBucket] = []
    @State private var isLoading = false
    @State private var hasLoadedOnce = false

    /// `envID::ref` currently being rechecked against its registry.
    @State private var checkingKeys: Set<String> = []
    /// `envID::resourceID` (image, container, or project) with an update in flight.
    @State private var updatingKeys: Set<String> = []
    @State private var rescanningEnvID: String?
    @State private var updaterRunTarget: UpdaterRunTarget?
    /// The image whose detail sheet is open.
    @State private var detailTarget: ImageDetailTarget?

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
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(buckets) { bucket in
                            environmentCard(for: bucket)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }
                .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            }
        }
        .navigationTitle("Updates")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $updaterRunTarget) { target in
            UpdaterRunView(environmentID: EnvironmentID(rawValue: target.envID))
        }
        .sheet(item: $detailTarget) { target in
            NavigationStack {
                imageDetailSheet(for: target)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .task { await loadAll() }
        .refreshable { await loadAll(refresh: true) }
        // Updates run through the app-wide deployment flow (pill + Live
        // Activity). When an operation this page started finishes, clear the
        // row spinners and refetch so updated images drop off the list.
        .onChange(of: DeploymentActivityStore.shared.isRunning) { _, running in
            guard !running, !updatingKeys.isEmpty else { return }
            updatingKeys.removeAll()
            Task { await loadAll(refresh: true) }
        }
    }

    private func updateCount(in bucket: EnvUpdateBucket) -> Int {
        let rows = outdatedImages(in: bucket).count
        // While a bucket's image list is still loading, trust its summary so
        // the headline and dashboard don't undercount mid-load.
        if rows == 0, bucket.loading, let summary = bucket.summary {
            return summary.imagesWithUpdates
        }
        return rows
    }

    // MARK: - Environment card

    @ViewBuilder
    private func environmentCard(for bucket: EnvUpdateBucket) -> some View {
        let outdated = outdatedImages(in: bucket)

        VStack(alignment: .leading, spacing: 0) {
            environmentHeader(for: bucket, outdatedCount: outdated.count)
                .padding(.bottom, 12)

            if let error = bucket.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.bottom, 10)
            }

            if bucket.loading && bucket.images.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking images…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 14)
            } else if outdated.isEmpty {
                allClearRow(for: bucket)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(outdated.enumerated()), id: \.element.id) { index, item in
                        outdatedImageRow(item, in: bucket)
                        if index < outdated.count - 1 {
                            Divider().padding(.leading, 48)
                        }
                    }
                }
            }

        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Plain-fill card, not glass: these cards animate height on
        // expand/collapse and Liquid Glass can't shrink smoothly.
        .dashboardCardBackground(cornerRadius: Radius.card)
    }

    private func environmentHeader(for bucket: EnvUpdateBucket, outdatedCount: Int) -> some View {
        HStack(spacing: 8) {
            Text(bucket.env.displayName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            environmentMenu(for: bucket, hasUpdates: outdatedCount > 0)
        }
    }

    /// Card-level actions live in a quiet header menu instead of footer
    /// buttons — rows carry the primary one-tap update already.
    @ViewBuilder
    private func environmentMenu(for bucket: EnvUpdateBucket, hasUpdates: Bool) -> some View {
        if rescanningEnvID == bucket.id {
            ProgressView()
                .controlSize(.small)
                .frame(width: 26, height: 26)
        } else {
            Menu {
                if hasUpdates {
                    Button {
                        updaterRunTarget = UpdaterRunTarget(envID: bucket.env.id)
                    } label: {
                        Label("Update All", systemImage: "arrow.up.circle")
                    }
                    .disabled(anyWorkInFlight(in: bucket))
                }
                Button {
                    Task { await recheckAll(bucket: bucket) }
                } label: {
                    Label("Recheck All", systemImage: "arrow.clockwise")
                }
                .disabled(rescanningEnvID != nil || bucket.loading)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
        }
    }

    private func allClearRow(for bucket: EnvUpdateBucket) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.green)
                .frame(width: 28, height: 28)
                .background(Color.green.opacity(0.12), in: .circle)
            Text(bucket.summary.map { "All \($0.totalImages) images up to date" } ?? "All images up to date")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }

    // MARK: - Outdated image row

    /// Deliberately quiet: icon, name, one line about what changed, and a
    /// single update glyph. Everything else lives in the detail sheet.
    @ViewBuilder
    private func outdatedImageRow(_ item: OutdatedImage, in bucket: EnvUpdateBucket) -> some View {
        let rowKey = key(bucket, item.image.id)
        let isUpdating = updatingKeys.contains(rowKey)
        let actionable = actionableConsumers(of: item)

        HStack(spacing: 12) {
            Button {
                detailTarget = ImageDetailTarget(envID: bucket.id, imageID: item.image.id)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "shippingbox.and.arrow.backward.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 36, height: 36)
                        .background(Color.orange.opacity(0.12), in: .circle)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(item.repoDisplayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            updateTypeBadge(item.info)
                        }
                        Text(verbatim: item.versionChange)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            // List-row rule: opacity-only press, no scale.
            .buttonStyle(.pressable(scales: false))

            if isUpdating {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 30)
            } else if !actionable.isEmpty {
                Button {
                    Task { await startImageUpdate(item, in: bucket) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3.weight(.semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.borderless)
                .tint(.orange)
                .disabled(anyWorkInFlight(in: bucket))
                .accessibilityLabel("Update \(item.repoDisplayName)")
            } else {
                recheckButton(for: item.ref, in: bucket)
            }
        }
        .padding(.vertical, 10)
        .contextMenu {
            if !actionable.isEmpty {
                Button {
                    Task { await startImageUpdate(item, in: bucket) }
                } label: {
                    Label("Update Image", systemImage: "arrow.up.circle.fill")
                }
                .disabled(anyWorkInFlight(in: bucket))
            }

            Button {
                Task { await recheck(bucket: bucket, ref: item.ref) }
            } label: {
                Label("Recheck Registry", systemImage: "arrow.clockwise")
            }
            .disabled(rescanningEnvID != nil)

            Button {
                UIPasteboard.general.string = item.ref
                showToast(.copied("Image ref copied"))
            } label: {
                Label("Copy Image Ref", systemImage: "doc.on.doc")
            }
        }
    }

    @ViewBuilder
    private func updateTypeBadge(_ info: ImageUpdateResponse) -> some View {
        let type = info.updateType
        if !type.isEmpty {
            let tint: Color = type.lowercased() == "digest" ? .blue : .orange
            Text(type.lowercased() == "digest" ? "Digest" : type.capitalized)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(tint.opacity(0.13), in: .capsule)
        }
    }

    // MARK: - Detail sheet

    /// Resolves the tapped image against live state so the sheet reflects
    /// updates as they land. If the image vanished after an update (its ID
    /// changes once the new image is pulled), show the all-done state.
    @ViewBuilder
    private func imageDetailSheet(for target: ImageDetailTarget) -> some View {
        if let bucket = buckets.first(where: { $0.id == target.envID }),
           let image = bucket.images.first(where: { $0.id == target.imageID }),
           let ref = primaryRef(of: image) {
            let info = resolvedInfo(for: image, ref: ref, in: bucket)
            imageDetailContent(
                item: OutdatedImage(image: image, ref: ref, info: info ?? ImageUpdateResponse()),
                hasUpdate: info?.hasUpdate == true,
                bucket: bucket
            )
        } else {
            updatedAwayState
        }
    }

    @ViewBuilder
    private func imageDetailContent(item: OutdatedImage, hasUpdate: Bool, bucket: EnvUpdateBucket) -> some View {
        let rowKey = key(bucket, item.image.id)
        let isUpdating = updatingKeys.contains(rowKey)
        let actionable = actionableConsumers(of: item)

        ScrollView {
            VStack(spacing: 16) {
                // Status hero
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill((hasUpdate ? Color.orange : .green).opacity(0.14))
                        Image(systemName: hasUpdate ? "arrow.up.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(hasUpdate ? Color.orange : .green)
                    }
                    .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(item.repoDisplayName)
                                .font(.headline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            updateTypeBadge(item.info)
                        }
                        Text(hasUpdate ? "Update available" : "Up to date")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: Radius.standard))

                // Full details — nothing truncated, everything selectable.
                VStack(alignment: .leading, spacing: 0) {
                    detailRow(label: "Image", value: item.ref, mono: true)
                    if !item.info.currentVersion.isEmpty {
                        Divider()
                        detailRow(label: "Current", value: item.info.currentVersion, mono: true)
                    }
                    if let latest = item.info.latestVersion, !latest.isEmpty {
                        Divider()
                        detailRow(label: "Latest", value: latest, mono: true, tint: hasUpdate ? .orange : nil)
                    }
                    if let digest = item.info.currentDigest, !digest.isEmpty {
                        Divider()
                        detailRow(label: "Current digest", value: digest, mono: true)
                    }
                    if let digest = item.info.latestDigest, !digest.isEmpty {
                        Divider()
                        detailRow(label: "New digest", value: digest, mono: true, tint: hasUpdate ? .orange : nil)
                    }
                    if let error = item.info.error, !error.isEmpty {
                        Divider()
                        detailRow(label: "Error", value: error, mono: false, tint: .red)
                    }
                }
                .padding(.horizontal, 16)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: Radius.standard))

                // Consumers with individual update actions.
                if !item.consumers.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Used By")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                        VStack(spacing: 0) {
                            ForEach(Array(item.consumers.enumerated()), id: \.offset) { index, consumer in
                                consumerRow(consumer, of: item, in: bucket, canUpdate: hasUpdate)
                                if index < item.consumers.count - 1 {
                                    Divider().padding(.leading, 38)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: Radius.standard))
                    }
                } else if !item.image.inUse {
                    Label("Not used by any container", systemImage: "moon.zzz")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: Radius.standard))
                }

                // Actions
                HStack(spacing: 10) {
                    Button {
                        Task { await recheck(bucket: bucket, ref: item.ref) }
                    } label: {
                        if checkingKeys.contains(key(bucket, item.ref)) {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Checking…")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Label("Recheck", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)

                    if hasUpdate && !actionable.isEmpty {
                        Button {
                            Task { await startImageUpdate(item, in: bucket) }
                        } label: {
                            if isUpdating {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Updating…")
                                }
                                .frame(maxWidth: .infinity)
                            } else {
                                Label(
                                    actionable.count == 1 ? "Update" : "Update All (\(actionable.count))",
                                    systemImage: "arrow.up.circle.fill"
                                )
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .tint(.orange)
                        .disabled(anyWorkInFlight(in: bucket))
                    }
                }
                .padding(.top, 4)
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(item.repoDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { detailTarget = nil }
            }
        }
    }

    /// Shown when the sheet's image no longer exists in the bucket — after a
    /// successful update the old image ID disappears from the list.
    private var updatedAwayState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.14))
                    .frame(width: 72, height: 72)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.green)
            }
            Text("All Set")
                .font(.title3.bold())
            Text("This image was updated and replaced by a newer version.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { detailTarget = nil }
            }
        }
    }

    private func detailRow(label: String, value: String, mono: Bool, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(mono ? .system(.footnote, design: .monospaced) : .footnote)
                .foregroundStyle(tint ?? .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func consumerRow(_ consumer: ImageUsedBy, of item: OutdatedImage, in bucket: EnvUpdateBucket, canUpdate: Bool) -> some View {
        let isProject = consumer.type == "project"
        let tint: Color = isProject ? .purple : .blue
        let consumerKey = consumer.id.map { key(bucket, $0) }
        let isUpdating = consumerKey.map(updatingKeys.contains) ?? false

        HStack(spacing: 10) {
            Image(systemName: isProject ? "folder.fill" : "shippingbox.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12), in: .circle)

            VStack(alignment: .leading, spacing: 1) {
                Text(consumer.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(isProject ? "Project" : "Container")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            if isUpdating {
                ProgressView().controlSize(.small)
            } else if canUpdate && consumer.id != nil {
                Button {
                    Task { await startConsumerUpdate(consumer, of: item, in: bucket) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .tint(.orange)
                .disabled(anyWorkInFlight(in: bucket))
                .accessibilityLabel("Update \(consumer.name)")
            }
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func recheckButton(for ref: String, in bucket: EnvUpdateBucket) -> some View {
        let checkKey = key(bucket, ref)
        if checkingKeys.contains(checkKey) {
            ProgressView().controlSize(.small)
        } else {
            Button {
                Task { await recheck(bucket: bucket, ref: ref) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .disabled(rescanningEnvID != nil)
        }
    }

    // MARK: - Derived rows

    /// Images with a confirmed pending update, name-sorted for stable
    /// ordering. Only tagged images can be checked and updated by ref.
    private func outdatedImages(in bucket: EnvUpdateBucket) -> [OutdatedImage] {
        bucket.images.compactMap { image -> OutdatedImage? in
            guard let ref = primaryRef(of: image),
                  let info = resolvedInfo(for: image, ref: ref, in: bucket),
                  info.hasUpdate
            else { return nil }
            return OutdatedImage(image: image, ref: ref, info: info)
        }
        .sorted { $0.repoDisplayName.localizedCaseInsensitiveCompare($1.repoDisplayName) == .orderedAscending }
    }

    private func primaryRef(of image: ImageSummary) -> String? {
        image.repoTags.first { $0 != "<none>:<none>" }
    }

    private func resolvedInfo(for image: ImageSummary, ref: String, in bucket: EnvUpdateBucket) -> ImageUpdateResponse? {
        if let cached = bucket.byRef[ref] { return cached }
        if let inline = image.updateInfo, inline.hasCheckResult { return inline.asUpdateResponse }
        return nil
    }

    private func actionableConsumers(of item: OutdatedImage) -> [ImageUsedBy] {
        item.consumers.filter {
            let name = $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = $0.id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Compose resources that were discovered outside Arcane may not
            // have a database ID. The tap-time resolver already supports
            // matching both projects and containers by name.
            return !name.isEmpty || !id.isEmpty
        }
    }

    private func key(_ bucket: EnvUpdateBucket, _ suffix: String) -> String {
        "\(bucket.id)::\(suffix)"
    }

    /// True while anything relevant is being updated — the deployment store
    /// only runs one operation at a time, so all update buttons pause while
    /// any operation is in flight.
    private func anyWorkInFlight(in bucket: EnvUpdateBucket) -> Bool {
        DeploymentActivityStore.shared.isRunning
            || updatingKeys.contains { $0.hasPrefix("\(bucket.id)::") }
            || rescanningEnvID != nil
    }

    // MARK: - Update actions

    /// Update every consumer of an outdated image through the app-wide
    /// deployment flow: floating pill, Live Activity, completion toast, and
    /// cache invalidation all come from `DeploymentActivityStore`.
    private func startImageUpdate(_ item: OutdatedImage, in bucket: EnvUpdateBucket) async {
        let targets = await resolveUpdateTargets(for: item.consumers, of: item, in: bucket)
        guard !targets.isEmpty else {
            showToast(.error("No matching containers found for \(item.repoDisplayName) — try refreshing"))
            return
        }
        startUpdateOperation(
            targets: targets, displayName: item.repoDisplayName,
            rowKey: key(bucket, item.image.id), in: bucket
        )
    }

    /// Update a single consumer — one container, or every container of a
    /// compose project — from the detail sheet.
    private func startConsumerUpdate(_ consumer: ImageUsedBy, of item: OutdatedImage, in bucket: EnvUpdateBucket) async {
        let targets = await resolveUpdateTargets(for: [consumer], of: item, in: bucket)
        guard !targets.isEmpty else {
            showToast(.error("No matching containers found for \(consumer.name) — try refreshing"))
            return
        }
        let rowKey = consumer.id.map { key(bucket, $0) } ?? key(bucket, item.image.id)
        startUpdateOperation(targets: targets, displayName: consumer.name, rowKey: rowKey, in: bucket)
    }

    /// Containers to update, resolved against a **fresh** containers list at
    /// tap time. The `usedBy` data captured at page load goes stale the
    /// moment a container is recreated (its ID changes), which made updates
    /// fail server-side with "container not found". Container consumers are
    /// re-matched by ID-then-name; project consumers expand to the project's
    /// containers running this image (the server's `updater/run` ignores
    /// resource scoping, so this expansion must happen client-side).
    private func resolveUpdateTargets(
        for consumers: [ImageUsedBy], of item: OutdatedImage, in bucket: EnvUpdateBucket
    ) async -> [DeploymentOperation.UpdateTarget] {
        let fresh = await freshContainers(in: bucket)

        var targets: [DeploymentOperation.UpdateTarget] = []
        for consumer in consumers {
            if consumer.type == "project" {
                let projectName = consumer.name.lowercased()
                let inProject = fresh.filter {
                    ($0.labels["com.docker.compose.project"] ?? "").lowercased() == projectName
                }
                let runningThisImage = inProject.filter { matches($0, image: item) }
                // If none of the project's containers still run this image
                // (already mid-update, or the list was stale), fall back to
                // the whole project — the server reports per-container truth.
                targets.append(contentsOf: (runningThisImage.isEmpty ? inProject : runningThisImage)
                    .map { .init(id: $0.id, name: displayName(of: $0)) })
            } else if let match = fresh.first(where: {
                $0.id == consumer.id || displayName(of: $0) == consumer.name
            }) {
                targets.append(.init(id: match.id, name: displayName(of: match)))
            } else if let id = consumer.id {
                // Container vanished from the fresh list — keep the captured
                // ID so the server can report what happened to it.
                targets.append(.init(id: id, name: consumer.name))
            }
        }

        var seen = Set<String>()
        return targets.filter { seen.insert($0.id).inserted }
    }

    /// Fetches the environment's containers through the cached **lenient**
    /// list path — the same recipe every container list in the app uses. The
    /// SDK's strict paginated decode can fail on a single odd container,
    /// which silently emptied this list and blocked updates.
    private func freshContainers(in bucket: EnvUpdateBucket) async -> [ContainerSummary] {
        guard let client = manager.client, let cached = manager.cached else { return [] }
        let envID = EnvironmentID(rawValue: bucket.env.id)
        let path = client.rest.environmentPath(envID, "containers")
        return (try? await cached.getList(
            path, elementType: ContainerSummary.self, policy: .containersList,
            envID: envID, refresh: true
        )) ?? []
    }

    private func matches(_ container: ContainerSummary, image item: OutdatedImage) -> Bool {
        if container.imageId == item.image.id { return true }
        return normalizedRef(container.image) == normalizedRef(item.ref)
    }

    /// Lowercased ref with any digest stripped and an explicit `:latest` tag,
    /// so `nginx`, `nginx:latest`, and `nginx@sha256:…` compare equal.
    private func normalizedRef(_ ref: String) -> String {
        var value = ref.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let at = value.firstIndex(of: "@") { value = String(value[..<at]) }
        if value.splitRefTag().tag == nil { value += ":latest" }
        return value
    }

    private func displayName(of container: ContainerSummary) -> String {
        container.names.first.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
            ?? String(container.id.prefix(12))
    }

    private func startUpdateOperation(
        targets: [DeploymentOperation.UpdateTarget], displayName: String,
        rowKey: String, in bucket: EnvUpdateBucket
    ) {
        let started = DeploymentActivityStore.shared.start(
            kind: .containerUpdate,
            envID: EnvironmentID(rawValue: bucket.env.id),
            targetID: targets[0].id,
            targetName: displayName,
            environmentName: bucket.env.displayName,
            manager: manager,
            mutationStore: mutationStore,
            updateTargets: targets
        )
        guard started else { return }
        updatingKeys.insert(rowKey)
        detailTarget = nil
        // Get out of the pill's way: progress lives on the root pill (and
        // Live Activity), and this page refreshes when the run ends.
        if dismissOnOperationStart {
            dismiss()
        }
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
        guard !envs.isEmpty else {
            publishUpdateCount()
            return
        }

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
        if !Task.isCancelled { publishUpdateCount() }
    }

    private func apply(result: EnvLoadResult) {
        guard buckets.indices.contains(result.index) else { return }
        var bucket = buckets[result.index]
        bucket.summary = result.summary
        bucket.images = result.images
        bucket.byRef = result.byRef
        bucket.totalImages = result.totalImages
        bucket.error = result.error
        bucket.loading = false
        buckets[result.index] = bucket
    }

    private nonisolated static func fetchEnv(
        index: Int, envID: EnvironmentID, client: ArcaneClient, pageSize: Int
    ) async -> EnvLoadResult {
        let summary: ImageUpdateSummary? = try? await client.images.updateSummary(envID: envID)

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
        var byRef: [String: ImageUpdateResponse] = [:]
        for image in images {
            guard let info = image.updateInfo, info.hasCheckResult else { continue }
            let response = info.asUpdateResponse
            for tag in image.repoTags where tag != "<none>:<none>" {
                byRef[tag] = response
            }
        }

        // Merge with the by-refs API. Its keys take precedence when present —
        // it has the freshest cached check results.
        if !refs.isEmpty,
           let map = try? await client.images.updateInfoByRefs(envID: envID, imageRefs: refs) {
            for (ref, info) in map {
                guard let info else { continue }
                byRef[ref] = info.asUpdateResponse
            }
        }

        // Only surface an error if we couldn't get either summary or images.
        let error: String? = (summary == nil && listError != nil) ? listError : nil

        return EnvLoadResult(
            index: index,
            summary: summary,
            images: images,
            byRef: byRef,
            totalImages: totalImages,
            error: error
        )
    }

    private func recheckAll(bucket: EnvUpdateBucket) async {
        guard let client = manager.client else { return }
        rescanningEnvID = bucket.id
        defer { rescanningEnvID = nil }

        let envID = EnvironmentID(rawValue: bucket.env.id)

        // Local envs return the batch map synchronously; remote envs sometimes
        // throw on decode (different response shape). Try the typed post
        // first, then refetch the env either way so remote envs still pick up
        // fresh results from the by-refs cache.
        let postedMap: ImageUpdateBatchResponse? =
            try? await client.images.checkAllUpdates(envID: envID)

        guard let index = buckets.firstIndex(where: { $0.id == bucket.id }) else { return }
        var result = await Self.fetchEnv(
            index: index, envID: envID, client: client, pageSize: Self.imagesPageSize
        )
        if let map = postedMap {
            // The synchronous check result is the freshest data available.
            result = result.merging(map.compactMapValues { $0 })
        }
        apply(result: result)
        publishUpdateCount()
    }

    private func recheck(bucket: EnvUpdateBucket, ref: String) async {
        guard let client = manager.client else { return }
        let checkKey = key(bucket, ref)
        checkingKeys.insert(checkKey)
        defer { checkingKeys.remove(checkKey) }
        let envID = EnvironmentID(rawValue: bucket.env.id)
        if let response = try? await client.images.checkUpdateByRef(envID: envID, imageRef: ref) {
            guard let index = buckets.firstIndex(where: { $0.id == bucket.id }) else { return }
            buckets[index].byRef[ref] = response
            publishUpdateCount()
        } else {
            showToast(.error("Couldn't check \(ref)"))
        }
    }

    private func publishUpdateCount() {
        let counts = Dictionary(uniqueKeysWithValues: buckets.map { bucket in
            (bucket.id, updateCount(in: bucket))
        })
        imageUpdateCountStore.setCounts(
            counts,
            client: manager.client,
            userID: manager.currentUser?.id
        )
    }
}

// MARK: - Models

struct EnvUpdateBucket: Identifiable {
    let env: Arcane.Environment
    var summary: ImageUpdateSummary?
    var images: [ImageSummary] = []
    var byRef: [String: ImageUpdateResponse] = [:]
    var totalImages: Int = 0
    var loading: Bool = false
    var error: String?

    var id: String { env.id }
}

/// A tagged image with a pending update (or, in the detail sheet, whatever
/// state it currently resolves to).
private struct OutdatedImage: Identifiable {
    let image: ImageSummary
    let ref: String
    let info: ImageUpdateResponse

    var id: String { image.id }
    var consumers: [ImageUsedBy] { image.usedBy ?? [] }

    /// `ghcr.io/foo/bar:1.2` → `bar` — the part people recognize; the full
    /// ref stays available in the detail sheet.
    var repoDisplayName: String {
        let repo = ref.splitRefTag().repo
        return repo.split(separator: "/").last.map(String.init) ?? repo
    }

    var versionChange: String {
        let current = info.currentVersion.isEmpty ? ref.splitRefTag().tag : info.currentVersion
        if let latest = info.latestVersion, !latest.isEmpty,
           let current, !current.isEmpty, latest != current {
            return "\(current) → \(latest)"
        }
        if info.updateType.lowercased() == "digest" {
            return "New digest for \(ref.splitRefTag().tag ?? "this tag")"
        }
        return ref
    }
}

private struct UpdaterRunTarget: Identifiable, Hashable {
    let envID: String
    var id: String { envID }
}

private struct ImageDetailTarget: Identifiable, Hashable {
    let envID: String
    let imageID: String
    var id: String { "\(envID)::\(imageID)" }
}

private struct EnvLoadResult: Sendable {
    let index: Int
    let summary: ImageUpdateSummary?
    let images: [ImageSummary]
    let byRef: [String: ImageUpdateResponse]
    let totalImages: Int
    let error: String?

    /// Overlay a fresh synchronous check-all result on top of this fetch.
    func merging(_ map: [String: ImageUpdateResponse]) -> EnvLoadResult {
        var merged = byRef
        merged.merge(map) { _, new in new }
        return EnvLoadResult(
            index: index, summary: summary, images: images,
            byRef: merged, totalImages: totalImages, error: error
        )
    }
}

private extension String {
    /// Splits `registry/repo:tag` into repo and tag, ignoring colons that
    /// belong to a registry port (`localhost:5000/foo`).
    nonisolated func splitRefTag() -> (repo: String, tag: String?) {
        guard let colon = lastIndex(of: ":") else { return (self, nil) }
        let afterColon = index(after: colon)
        let tail = self[afterColon...]
        // A colon inside the registry host segment is followed by a `/`.
        if tail.contains("/") { return (self, nil) }
        return (String(self[..<colon]), String(tail))
    }
}
