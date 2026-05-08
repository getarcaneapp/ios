import SwiftUI
import Arcane

struct ImageDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let image: ImageInfo
    let environmentID: EnvironmentID

    @State private var details: ImageDetails?
    @State private var isLoading = false
    @State private var showDeleteConfirm = false
    @State private var errorMessage: String?
    @State private var updateInfo: ImageUpdateResponse?
    @State private var isCheckingUpdate = false
    @State private var vulnSummary: ScanSummary?
    @State private var scannerStatus: ScannerStatus?

    var body: some View {
        List {
            Section {
                imageHeader
            }

            if let details {
                Section("Details") {
                    LabeledContent("Created", value: details.created.formattedDate)
                    LabeledContent("Architecture", value: details.architecture)
                    LabeledContent("OS", value: details.os)
                    LabeledContent("Size", value: details.size.byteString)
                    if !details.author.isEmpty {
                        let author = details.author
                        LabeledContent("Author", value: author)
                    }
                }

                if let tags = details.repoTags, !tags.isEmpty {
                    Section("Tags") {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag).font(.caption.monospaced())
                        }
                        updateCheckRow
                    }
                }

                if let digests = details.repoDigests, !digests.isEmpty {
                    Section("Digests") {
                        ForEach(digests, id: \.self) { digest in
                            Text(digest)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }
                    }
                }

                imageConfigSection(details.config)

                vulnerabilitiesSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Image Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
            }
        }
        .task { await loadDetails() }
        .confirmationDialog("Remove Image", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await removeImage() } }
        } message: {
            Text("This will remove the image from the host.")
        }
    }

    private var imageHeader: some View {
        HStack(spacing: 16) {
            Image(systemName: "photo.stack.fill")
                .font(.title)
                .foregroundStyle(.purple)
                .frame(width: 56, height: 56)
                .glassEffect(.regular, in: .circle)

            VStack(alignment: .leading, spacing: 4) {
                Text(image.displayName)
                    .font(.title3.bold())
                    .lineLimit(2)
                Text(image.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(image.size.byteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func imageConfigSection(_ config: ImageConfig) -> some View {
        Section("Image Config") {
            if let cmd = config.cmd, !cmd.isEmpty {
                LabeledContent("CMD", value: cmd.joined(separator: " "))
            }
            if let ep = config.entrypoint, !ep.isEmpty {
                LabeledContent("Entrypoint", value: ep.joined(separator: " "))
            }
            if let wd = config.workingDir, !wd.isEmpty {
                LabeledContent("Working Dir", value: wd)
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

    @ViewBuilder
    private var updateCheckRow: some View {
        if isCheckingUpdate {
            HStack {
                Text("Checking for updates…").foregroundStyle(.secondary)
                Spacer()
                ProgressView().scaleEffect(0.8)
            }
        } else if let info = updateInfo {
            if let err = info.error, !err.isEmpty {
                Label(err, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.caption)
            } else if info.hasUpdate {
                HStack {
                    Image(systemName: "arrow.up.circle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Update available").font(.caption.bold())
                        if let latest = info.latestVersion, let current = info.currentVersion, latest != current {
                            Text("\(current) → \(latest)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Recheck") { Task { await checkForUpdate() } }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            } else {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Up to date").font(.caption)
                    Spacer()
                    Button("Recheck") { Task { await checkForUpdate() } }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        } else {
            Button {
                Task { await checkForUpdate() }
            } label: {
                Label("Check for updates", systemImage: "arrow.up.arrow.down.circle")
            }
        }
    }

    @ViewBuilder
    private var vulnerabilitiesSection: some View {
        Section("Vulnerabilities") {
            if let summary = vulnSummary {
                NavigationLink(destination: ImageVulnerabilitiesView(imageID: image.id, imageDisplayName: image.displayName, environmentID: environmentID)) {
                    SeveritySummaryRow(
                        summary: summary.summary,
                        scanTime: summary.scanTime,
                        status: summary.status,
                        error: summary.error
                    )
                }
            } else if scannerStatus?.available == false {
                Label("Scanner unavailable on host", systemImage: "shield.slash")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                NavigationLink(destination: ImageVulnerabilitiesView(imageID: image.id, imageDisplayName: image.displayName, environmentID: environmentID)) {
                    Label("Not scanned yet — open to scan", systemImage: "shield")
                }
            }
        }
    }

    private func loadDetails() async {
        guard let client = manager.client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let path = client.rest.environmentPath(environmentID, "images/\(image.id)")
            details = try await client.rest.get(path)
        } catch {}
        await loadVulnerabilitySummary()
    }

    private func loadVulnerabilitySummary() async {
        guard let client = manager.client else { return }
        async let statusTask: ScannerStatus? = try? client.rest.get(client.rest.environmentPath(environmentID, "vulnerabilities/scanner-status"))
        async let summaryTask: ScanSummary? = try? client.rest.get(client.rest.environmentPath(environmentID, "images/\(image.id)/vulnerabilities/summary"))
        scannerStatus = await statusTask
        vulnSummary = await summaryTask
    }

    private func checkForUpdate() async {
        guard let client = manager.client else { return }
        isCheckingUpdate = true
        defer { isCheckingUpdate = false }
        do {
            let path = client.rest.environmentPath(environmentID, "image-updates/check/\(image.id)")
            let response: ImageUpdateResponse = try await client.rest.post(path, body: String?.none)
            updateInfo = response
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func removeImage() async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "images/\(image.id)")
            let _: DataResponse<String> = try await client.rest.delete(path)
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

private extension String {
    var formattedDate: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: self) {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return self
    }
}
