import SwiftUI
import Arcane

struct ImageDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let image: ImageSummary
    let environmentID: EnvironmentID

    @State private var details: ImageDetailSummary?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var updateInfo: ImageUpdateResponse?
    @State private var isCheckingUpdate = false
    @State private var usingContainers: [ContainerSummary] = []
    @State private var selectedSection: DetailSection = .overview

    private enum DetailSection: String, CaseIterable, Identifiable {
        case overview, history, attestations, vulnerabilities
        var id: String { rawValue }
        var title: String { rawValue.capitalized }

        var systemImage: String {
            switch self {
            case .overview: "info.circle.fill"
            case .history: "square.stack.3d.down.right.fill"
            case .attestations: "checkmark.seal.fill"
            case .vulnerabilities: "shield.lefthalf.filled"
            }
        }

        var tint: Color {
            switch self {
            case .overview: .purple
            case .history: .blue
            case .attestations: .green
            case .vulnerabilities: .orange
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            detailSectionTabs

            switch selectedSection {
            case .overview:
                overview
            case .history:
                ImageHistoryView(imageID: image.id, environmentID: environmentID)
            case .attestations:
                ImageAttestationsView(
                    imageID: image.id,
                    imageDisplayName: image.displayName,
                    environmentID: environmentID,
                    embedded: true
                )
            case .vulnerabilities:
                ImageVulnerabilitiesView(
                    imageID: image.id,
                    imageDisplayName: image.displayName,
                    environmentID: environmentID,
                    embedded: true
                )
            }
        }
        .motionAwareAnimation(Motion.state, value: selectedSection)
        .morphingActions(
            primary: ActionButtonItem(
                id: "recheck",
                title: "Recheck for Updates",
                systemImage: "arrow.triangle.2.circlepath",
                tint: .accentColor
            ) {
                Task { await checkForUpdate() }
            },
            inline: [
                ActionButtonItem(
                    id: "remove",
                    title: "Remove Image",
                    systemImage: "trash",
                    tint: .red,
                    role: .destructive,
                    confirmationMessage: "This will remove the image from the host."
                ) {
                    Task { await removeImage() }
                }
            ],
            runningItemID: isCheckingUpdate ? "recheck" : nil,
            isDisabled: isCheckingUpdate
        )
        .navigationTitle("Image Details")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadDetails() }
        .task { await loadUpdateStatus() }
        .task { await loadUsingContainers() }
        .alert(
            "Error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var detailSectionTabs: some View {
        ScrollableTabBar(
            selection: $selectedSection,
            options: DetailSection.allCases.map {
                ScrollableTabOption(
                    $0,
                    title: $0.title,
                    systemImage: $0.systemImage,
                    tint: $0.tint
                )
            },
            accessibilityLabel: "Image detail sections"
        )
    }

    private var overview: some View {
        List {
            Section {
                imageHeader
            }

            if let details {
                Section {
                    AdaptiveMetadataGrid(items: metadataItems(details))
                }

                Section {
                    LabeledContent("Image ID") { MonospacedValue(value: details.id, lineLimit: 1) }
                    if !details.repoTags.isEmpty {
                        LabeledContent("Tags") { MonospacedValue(value: details.repoTags.joined(separator: "\n")) }
                    }
                } header: {
                    ResourceSectionHeader(title: "Identity", systemImage: "number")
                }
            }

            if !usingContainers.isEmpty {
                Section("Used By") {
                    ForEach(usingContainers) { container in
                        NavigationLink {
                            ContainerDetailView(container: container, environmentID: environmentID)
                        } label: {
                            HStack(spacing: 10) {
                                StatusIcon(status: container.status, isLive: container.isRunning)
                                Text(container.displayName)
                            }
                        }
                    }
                }
            }

            if let details {
                if details.repoTags.count > 1 {
                    let tags = details.repoTags
                    Section("Tags") {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag).font(.caption.monospaced())
                        }
                    }
                }

                imageConfigSection(details.config)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func metadataItems(_ details: ImageDetailSummary) -> [ResourceMetadataItem] {
        [
            ResourceMetadataItem(label: "Size", value: details.size.byteString, systemImage: "internaldrive"),
            ResourceMetadataItem(label: "Created", value: headerDate(details.created), systemImage: "calendar"),
            ResourceMetadataItem(label: "Platform", value: "\(details.os)/\(details.architecture)", systemImage: "cpu"),
            ResourceMetadataItem(label: "Author", value: nonEmptyResourceValue(details.author) ?? "Unknown", systemImage: "person"),
            ResourceMetadataItem(label: "Docker", value: nonEmptyResourceValue(details.dockerVersion) ?? "Unknown", systemImage: "shippingbox"),
            ResourceMetadataItem(label: "Consumers", value: String(usingContainers.count), systemImage: "cube.box")
        ]
    }

    private var imageHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: "photo.stack.fill")
                .font(.title2)
                .foregroundStyle(.purple)
                .frame(width: 48, height: 48)
                .glassEffectCompat(in: .circle)

            VStack(alignment: .leading, spacing: 3) {
                Text(image.displayName)
                    .font(.headline)
                Text(image.id)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(image.size.byteString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let details {
                    Text("\(details.os)/\(details.architecture)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(headerDate(details.created))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if isCheckingUpdate {
                    HStack(spacing: 5) {
                        ProgressView().scaleEffect(0.6)
                        Text("Checking…").font(.caption2).foregroundStyle(.secondary)
                    }
                } else if updateState != .unknown {
                    UpdateStateBadge(state: updateState)
                }
                if let info = updateInfo, info.hasUpdate,
                   let latest = info.latestVersion, !info.currentVersion.isEmpty,
                   latest != info.currentVersion {
                    Text("\(info.currentVersion) → \(latest)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func headerDate(_ iso: String) -> String {
        ArcaneDateFormatting.formattedISO8601(iso, date: .abbreviated, time: .omitted)
    }

    private func imageConfigSection(_ config: ImageDetailConfig) -> some View {
        Section("Image Config") {
            if let cmd = config.cmd, !cmd.isEmpty {
                LabeledContent("CMD") { MonospacedValue(value: cmd.joined(separator: " ")) }
            }
            if let ep = config.entrypoint, !ep.isEmpty {
                LabeledContent("Entrypoint") { MonospacedValue(value: ep.joined(separator: " ")) }
            }
            if let wd = config.workingDir, !wd.isEmpty {
                LabeledContent("Working Dir") { MonospacedValue(value: wd) }
            }
            if let user = config.user, !user.isEmpty {
                LabeledContent("User", value: user)
            }
            if let env = config.env, !env.isEmpty {
                NavigationLink("Env Vars (\(env.count))") {
                    EnvVarsView(vars: env)
                }
            }
            if let labels = config.labels, !labels.isEmpty {
                NavigationLink("Labels (\(labels.count))") {
                    LabelsView(labels: labels)
                }
            }
        }
    }

    // List-style update state derived from the fetched update info, shown as a
    // compact badge in the header (matches the Images list).
    private var updateState: ImageUpdateState {
        guard let info = updateInfo else { return .unknown }
        if let err = info.error, !err.isEmpty { return .error(err) }
        if info.hasUpdate { return .hasUpdate }
        return .upToDate
    }

    private func loadDetails(refresh: Bool = false) async {
        guard let client = manager.client, let cached = manager.cached else { return }
        if details == nil { isLoading = true }
        defer { isLoading = false }
        do {
            let path = client.rest.environmentPath(environmentID, "images/\(image.id)")
            if let result: ImageDetailSummary = try await cached.get(
                path, as: ImageDetailSummary.self, policy: .imageDetail,
                envID: environmentID, refresh: refresh,
                onFresh: { fresh in details = fresh }
            ) {
                details = result
            }
        } catch {}
    }

    private func checkForUpdate() async {
        guard let client = manager.client else { return }
        isCheckingUpdate = true
        defer { isCheckingUpdate = false }
        do {
            updateInfo = try await client.images.checkUpdateByIDPost(envID: environmentID, imageId: image.id)
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    /// Loads the last-known update status (cheap, cached) for the header without
    /// forcing a fresh registry check. The navbar "Recheck" forces a fresh one.
    private func loadUpdateStatus() async {
        guard let client = manager.client else { return }
        let refs = image.repoTags.filter { $0 != "<none>:<none>" }
        guard !refs.isEmpty else { return }
        do {
            let map = try await client.images.updateInfoByRefs(envID: environmentID, imageRefs: refs)
            for tag in refs {
                if let info = map[tag], let info {
                    updateInfo = info.asUpdateResponse
                    break
                }
            }
        } catch {
            // Best-effort; the navbar recheck can force a fresh check.
        }
    }

    private func loadUsingContainers() async {
        guard let client = manager.client, let cached = manager.cached else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "containers")
            if let all = try await cached.getAllPages(
                path: path, elementType: ContainerSummary.self, policy: .containersList,
                envID: environmentID,
                fetchPage: { start, limit in
                    let response = try await client.containers.list(
                        envID: environmentID,
                        query: .init(start: start, limit: limit)
                    )
                    return ResourcePage(items: response.data, pagination: response.pagination)
                }
            ) {
                usingContainers = all.filter(usesThisImage)
            }
        } catch {
            // Best-effort decoration.
        }
    }

    private func usesThisImage(_ container: ContainerSummary) -> Bool {
        // Primary: same resolved image id (sha), tolerant of short ids / prefix.
        let imageHex = normalizedID(image.id)
        let containerHex = normalizedID(container.imageId)
        if !imageHex.isEmpty, !containerHex.isEmpty,
           imageHex == containerHex || imageHex.hasPrefix(containerHex) || containerHex.hasPrefix(imageHex) {
            return true
        }
        // Fallback: the container's image ref matches one of this image's tags,
        // ignoring implicit Docker Hub registry/namespace prefixes and any digest.
        let containerRef = normalizedRef(container.image)
        return image.repoTags.contains { normalizedRef($0) == containerRef }
    }

    private func normalizedID(_ id: String) -> String {
        id.hasPrefix("sha256:") ? String(id.dropFirst(7)) : id
    }

    private func normalizedRef(_ ref: String) -> String {
        var r = ref
        if let at = r.firstIndex(of: "@") { r = String(r[..<at]) }  // drop @sha256:… digest
        for prefix in ["index.docker.io/library/", "index.docker.io/", "docker.io/library/", "docker.io/", "library/"] {
            if r.hasPrefix(prefix) { r = String(r.dropFirst(prefix.count)); break }
        }
        return r
    }

    private func removeImage() async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "images/\(image.id)")
            let _: DataResponse<String> = try await client.rest.delete(path)
            if let cached = manager.cached {
                await cached.invalidate(envID: environmentID, paths: [
                    client.rest.environmentPath(environmentID, "images") + "*",
                    client.rest.environmentPath(environmentID, "images/*")
                ])
            }
            mutationStore.markChanged(kind: .images, envID: environmentID)
            dismiss()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

private extension String {
    var formattedDate: String {
        ArcaneDateFormatting.formattedISO8601(self, date: .abbreviated, time: .shortened)
    }
}
