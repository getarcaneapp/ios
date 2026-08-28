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
        ScrollView {
            LazyVStack(spacing: 16) {
                headerCard

                if let details {
                    metadataCard(details)
                    identityCard(details)
                }

                if !usingContainers.isEmpty {
                    usedByCard
                }

                if let details {
                    if details.repoTags.count > 1 {
                        tagsCard(details.repoTags)
                    }

                    configCard(details.config)
                }
            }
            .padding(.top, 8)
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .softTopScrollEdgeEffectCompat()
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var headerCard: some View {
        imageHeader
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dashboardCardBackground()
    }

    private func metadataCard(_ details: ImageDetailSummary) -> some View {
        AdaptiveMetadataGrid(items: metadataItems(details))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dashboardCardBackground(cornerRadius: Radius.standard)
    }

    private func identityCard(_ details: ImageDetailSummary) -> some View {
        infoRowCard(title: "Identity", systemImage: "number") {
            valueRow("Image ID", monospacedValue: details.id)
            if !details.repoTags.isEmpty {
                Divider().padding(.leading, 12)
                valueRow("Tags", monospacedValue: details.repoTags.joined(separator: "\n"))
            }
        }
    }

    private var usedByCard: some View {
        infoRowCard(title: "Used By", systemImage: "cube.box", count: usingContainers.count) {
            ForEach(Array(usingContainers.enumerated()), id: \.element.id) { index, container in
                if index > 0 { Divider().padding(.leading, 12) }
                NavigationLink {
                    ContainerDetailView(container: container, environmentID: environmentID)
                } label: {
                    HStack(spacing: 10) {
                        StatusIcon(status: container.status, isLive: container.isRunning)
                        Text(container.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary.opacity(0.5))
                    }
                    .padding(12)
                    .contentShape(.rect)
                }
                .cardRowLinkStyle()
            }
        }
    }

    private func tagsCard(_ tags: [String]) -> some View {
        infoRowCard(title: "Tags", systemImage: "tag") {
            ForEach(Array(tags.enumerated()), id: \.element) { index, tag in
                if index > 0 { Divider().padding(.leading, 12) }
                MonospacedValue(value: tag)
                    .font(.caption.monospaced())
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func configCard(_ config: ImageDetailConfig) -> some View {
        let rows = configRows(config)
        guard !rows.isEmpty else {
            return AnyView(EmptyView())
        }
        return AnyView(
            infoRowCard(title: "Image Config", systemImage: "slider.horizontal.3") {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider().padding(.leading, 12) }
                    switch row {
                    case .value(let label, let value):
                        valueRow(label, monospacedValue: value)
                    case .text(let label, let value):
                        valueRow(label, textValue: value)
                    case .link(let title):
                        configNavLink(title) {
                            if title.hasPrefix("Env") {
                                EnvVarsView(vars: config.env ?? [])
                            } else {
                                LabelsView(labels: config.labels ?? [:])
                            }
                        }
                    }
                }
            }
        )
    }

    private enum ConfigRow {
        case value(String, String)
        case text(String, String)
        case link(String)
    }

    private func configRows(_ config: ImageDetailConfig) -> [ConfigRow] {
        var rows: [ConfigRow] = []
        if let cmd = config.cmd, !cmd.isEmpty { rows.append(.value("CMD", cmd.joined(separator: " "))) }
        if let ep = config.entrypoint, !ep.isEmpty { rows.append(.value("Entrypoint", ep.joined(separator: " "))) }
        if let wd = config.workingDir, !wd.isEmpty { rows.append(.value("Working Dir", wd)) }
        if let user = config.user, !user.isEmpty { rows.append(.text("User", user)) }
        if let env = config.env, !env.isEmpty { rows.append(.link("Env Vars (\(env.count))")) }
        if let labels = config.labels, !labels.isEmpty { rows.append(.link("Labels (\(labels.count))")) }
        return rows
    }

    /// Grouped card of label/value rows, mirroring the dashboard's
    /// `DashboardInfoGroup`/`DashboardInfoRow` pair.
    private func infoRowCard<Content: View>(
        title: String,
        systemImage: String,
        count: Int? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title, systemImage: systemImage, count: count)
            VStack(spacing: 0) { content() }
                .dashboardCardBackground(cornerRadius: Radius.standard)
        }
    }

    /// Label stacked above the value so long monospace content (image IDs,
    /// tag lists) wraps across the full card width instead of being squeezed
    /// into the remaining space next to the label.
    private func valueRow(
        _ label: String,
        monospacedValue: String,
        lineLimit: Int? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: monospacedValue)
                .font(.subheadline.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(lineLimit)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func valueRow(_ label: String, textValue: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(textValue)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func configNavLink<Destination: View>(_ title: String, @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink(destination: destination()) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary.opacity(0.5))
            }
            .padding(12)
            .contentShape(.rect)
        }
        .cardRowLinkStyle()
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
