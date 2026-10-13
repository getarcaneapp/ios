import Arcane
import SwiftUI

struct GitOpsSyncDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(EnvironmentsStore.self) private var environmentsStore: EnvironmentsStore?
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(\.openURL) private var openURL

    /// The environment the sync belongs to, which can differ from the active one
    /// in All Environments lists.
    let environmentID: EnvironmentID
    /// Called after an action changes the sync so the presenting list can reload.
    var onChange: () -> Void = {}

    @State private var sync: GitOpsSyncDetails
    /// Raw sync from the last reload; seeds the edit form.
    @State private var resource: DynamicResource?
    @State private var runningActionID: String?
    @State private var showEdit = false

    init(sync: GitOpsSyncDetails, environmentID: EnvironmentID, onChange: @escaping () -> Void = {}) {
        _sync = State(initialValue: sync)
        self.environmentID = environmentID
        self.onChange = onChange
    }

    var body: some View {
        List {
            Section { header }
            if let error = sync.visibleError {
                errorSection(error)
            }
            sourceSection
            if sync.isBackup {
                backupSection
                backupPathsSection
            } else {
                lastSyncSection
                automationSection
                preDeploySection
            }
            syncedFilesSection
            detailsSection
        }
        .listStyle(.insetGrouped)
        .softTopScrollEdgeEffectCompat()
        .navigationTitle(sync.name)
        .navigationBarTitleDisplayMode(.inline)
        .resourceActionsToolbar(
            primary: syncAction,
            overflow: overflowActions,
            runningItemID: runningActionID,
            isDisabled: runningActionID != nil,
            resourceName: sync.name
        )
        .task { await reload() }
        .refreshable { await reload() }
        .sheet(isPresented: $showEdit) {
            if let resource {
                let config = GitOpsSyncsView.editConfig
                DynamicCreateFormView(title: config.title, fields: config.fields, initial: resource) { data in
                    guard let client = manager.client, let syncPath else { return }
                    _ = try await ArcaneAPIHelpers.send(
                        client: client, path: syncPath, method: config.method, body: data)
                    showToast(.success("Sync updated"))
                    onChange()
                    await reload()
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: sync.isBackup ? "arrow.up.doc.fill" : "arrow.triangle.merge")
                .font(.title)
                .foregroundStyle(.indigo)
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(sync.name)
                    .font(.title3.bold())
                Text(sync.isBackup ? "Backs up to Git" : "Deploys from Git")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ResourceStatusBadge(
                    status: sync.statusPresentation.status,
                    usesCardStyle: true,
                    label: sync.statusPresentation.label
                )
                .padding(.top, 2)
            }
        }
    }

    private func errorSection(_ error: String) -> some View {
        Section {
            Text(verbatim: error)
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
            if sync.isBackup, let reason = sync.backupFailureDescription {
                LabeledContent("Reason", value: reason)
            }
        } header: {
            Label(sync.isBackup ? "Backup Error" : "Sync Error", systemImage: "exclamationmark.triangle")
        }
    }

    // MARK: - Sections

    private var sourceSection: some View {
        detailSection(title: "Repository", systemImage: "externaldrive.connected.to.line.below") {
            LabeledContent("Repository") {
                Text(verbatim: sync.repositoryName ?? sync.repositoryURL ?? "Unknown")
            }
            if sync.repositoryName != nil, let url = sync.repositoryURL {
                LabeledContent("URL") { MonospacedValue(value: url, lineLimit: 1) }
            }
            if let branch = sync.branch {
                LabeledContent("Branch") { MonospacedValue(value: branch, lineLimit: 1) }
            }
            if sync.isBackup {
                LabeledContent("Backup Directory") {
                    MonospacedValue(value: sync.backupDirectory ?? "/", lineLimit: 2)
                }
            } else if let composePath = sync.composePath {
                LabeledContent("Compose File") { MonospacedValue(value: composePath, lineLimit: 2) }
            }
            projectRow
            if let url = sync.repositoryWebURL {
                Link(destination: url) {
                    Label("Open Repository", systemImage: "arrow.up.right.square")
                }
            }
        }
    }

    @ViewBuilder
    private var projectRow: some View {
        let name = sync.projectName ?? "Not created yet"
        if let projectID = sync.projectID, !sync.isSwarmStack {
            NavigationLink {
                GitOpsProjectDestination(projectID: projectID, environmentID: environmentID)
            } label: {
                LabeledContent("Project") { Text(verbatim: name) }
            }
        } else {
            LabeledContent(sync.targetLabel) { Text(verbatim: name) }
        }
    }

    private var lastSyncSection: some View {
        detailSection(title: "Last Sync", systemImage: "clock.arrow.circlepath") {
            LabeledContent("Status") {
                ResourceStatusBadge(status: sync.statusPresentation.status, label: sync.statusPresentation.label)
            }
            dateRow("Synced", sync.lastSyncAt)
            commitRow
        }
    }

    private var automationSection: some View {
        detailSection(title: "Automation", systemImage: "gearshape.2") {
            LabeledContent("Auto Sync", value: sync.autoSync ? sync.syncIntervalDescription : "Off")
            LabeledContent("Sync Scope", value: sync.syncDirectory ? "Entire directory" : "Compose file only")
            LabeledContent("Pull Images After Sync", value: sync.pullImageAfterSync ? "On" : "Off")
            LabeledContent("Redeploy After Sync", value: sync.redeployAfterSync ? "On" : "Off")
        }
    }

    @ViewBuilder
    private var preDeploySection: some View {
        if let script = sync.preDeployScriptPath {
            detailSection(title: "Pre-Deploy Hook", systemImage: "terminal") {
                LabeledContent("Script") { MonospacedValue(value: script, lineLimit: 2) }
                if let image = sync.preDeployRunnerImage {
                    LabeledContent("Runner Image") { MonospacedValue(value: image, lineLimit: 1) }
                }
                if let status = sync.preDeployLastRunStatus {
                    LabeledContent("Last Run") {
                        ResourceStatusBadge(status: status == "timeout" ? "failed" : status, label: status.capitalized)
                    }
                }
                if sync.preDeployLastRunAt != nil {
                    dateRow("Ran", sync.preDeployLastRunAt)
                }
            }
        }
    }

    private var backupSection: some View {
        detailSection(title: "Backup", systemImage: "arrow.up.doc") {
            LabeledContent("State") {
                ResourceStatusBadge(status: sync.statusPresentation.status, label: sync.statusPresentation.label)
            }
            dateRow("Last Backup", sync.lastBackupAt)
            dateRow("Last Check", sync.lastSyncAt)
            commitRow
            LabeledContent("Trigger", value: sync.backupOnSave ? "On Save" : "Manual")
            if sync.backupPending {
                LabeledContent("Pending Changes", value: "Waiting to push")
            }
        }
    }

    private var backupPathsSection: some View {
        Section {
            if sync.backupPaths.isEmpty {
                Text("Compose files only")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sync.backupPaths, id: \.self) { path in
                    pathRow(path)
                }
            }
        } header: {
            Label("Backup Paths", systemImage: "folder")
        } footer: {
            Text("Compose files are always included.")
        }
    }

    @ViewBuilder
    private var syncedFilesSection: some View {
        if !sync.syncedFiles.isEmpty {
            Section {
                DisclosureGroup {
                    ForEach(sync.syncedFiles, id: \.self) { path in
                        pathRow(path)
                    }
                } label: {
                    LabeledContent(sync.isBackup ? "Files in Last Backup" : "Synced Files") {
                        Text(verbatim: String(sync.syncedFiles.count))
                    }
                }
            }
        }
    }

    private var detailsSection: some View {
        detailSection(title: "Details", systemImage: "info.circle") {
            if let environmentName = environmentsStore?.displayName(for: environmentID) {
                LabeledContent("Environment") { Text(verbatim: environmentName) }
            }
            if sync.maxSyncFiles > 0 {
                LabeledContent("File Limit") { Text(verbatim: String(sync.maxSyncFiles)) }
            }
            if sync.maxSyncTotalSize > 0 {
                LabeledContent("Total Size Limit", value: byteCount(sync.maxSyncTotalSize))
            }
            if sync.maxSyncBinarySize > 0 {
                LabeledContent("Binary File Limit", value: byteCount(sync.maxSyncBinarySize))
            }
            if let createdAt = sync.createdAt {
                LabeledContent("Created", value: createdAt.formatted(date: .abbreviated, time: .shortened))
            }
            if let updatedAt = sync.updatedAt {
                LabeledContent("Updated", value: updatedAt.formatted(date: .abbreviated, time: .shortened))
            }
            LabeledContent("Sync ID") {
                MonospacedValue(value: sync.id, lineLimit: 1)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .contextMenu {
                copyButton("Copy Sync ID", value: sync.id)
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private var commitRow: some View {
        if let commit = sync.lastSyncCommit, let short = sync.shortCommit {
            LabeledContent("Commit") {
                if let url = sync.commitURL {
                    Link(destination: url) {
                        Text(verbatim: short).font(.body.monospaced())
                    }
                } else {
                    Text(verbatim: short).font(.body.monospaced())
                }
            }
            .contextMenu {
                copyButton("Copy Commit Hash", value: commit)
                if let url = sync.commitURL {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Open Commit", systemImage: "arrow.up.right.square")
                    }
                }
            }
        }
    }

    private func dateRow(_ label: String, _ date: Date?) -> some View {
        LabeledContent(label) {
            if let date {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(date, format: .relative(presentation: .named))
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("Never")
            }
        }
    }

    private func pathRow(_ path: String) -> some View {
        Label {
            Text(verbatim: path)
                .font(.callout.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: path.hasSuffix("/") ? "folder" : "doc.text")
                .foregroundStyle(.secondary)
        }
    }

    private func copyButton(_ title: String, value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            showToast(.copied())
        } label: {
            Label(title, systemImage: "doc.on.doc")
        }
    }

    private func detailSection<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Section {
            content()
        } header: {
            Label(title, systemImage: systemImage)
        }
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Actions

    private var syncAction: ActionButtonItem {
        if sync.isBackup {
            return ActionButtonItem(
                id: "sync", title: "Back Up Now", systemImage: "arrow.up.circle", tint: .accentColor
            ) {
                Task { await performSync() }
            }
        }
        return ActionButtonItem(
            id: "sync", title: "Sync Now", systemImage: "arrow.triangle.2.circlepath", tint: .accentColor
        ) {
            Task { await performSync() }
        }
    }

    private var overflowActions: [ActionButtonItem] {
        var items: [ActionButtonItem] = []
        if let url = sync.repositoryWebURL {
            items.append(
                ActionButtonItem(
                    id: "open-repository", title: "Open Repository", systemImage: "arrow.up.right.square",
                    tint: .accentColor
                ) {
                    openURL(url)
                })
        }
        if !sync.isBackup, resource != nil {
            items.append(
                ActionButtonItem(id: "edit", title: "Edit", systemImage: "pencil", tint: .accentColor) {
                    showEdit = true
                })
        }
        if sync.isBackup {
            items.append(
                ActionButtonItem(
                    id: "delete",
                    title: "Stop Backing Up",
                    systemImage: "xmark.circle",
                    tint: .red,
                    role: .destructive,
                    confirmationMessage:
                        "Arcane stops backing this project up to Git. Local files and the repository history are kept."
                ) {
                    Task { await deleteSync() }
                })
        } else {
            items.append(
                ActionButtonItem(
                    id: "delete",
                    title: "Delete Sync",
                    systemImage: "trash",
                    tint: .red,
                    role: .destructive,
                    confirmationMessage: "This removes the sync configuration. The project and its files are kept."
                ) {
                    Task { await deleteSync() }
                })
        }
        return items
    }

    private var syncPath: String? {
        manager.client.map {
            $0.rest.environmentPath(
                environmentID, "gitops-syncs/\(ArcaneAPIHelpers.escapedPathComponent(sync.id))")
        }
    }

    private func reload() async {
        guard let client = manager.client, let syncPath else { return }
        do {
            let resource: DynamicResource = try await client.rest.get(syncPath)
            self.resource = resource
            sync = GitOpsSyncDetails(resource: resource)
        } catch is CancellationError {
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }

    private func performSync() async {
        guard let client = manager.client else { return }
        runningActionID = "sync"
        defer { runningActionID = nil }
        do {
            let result = try await client.gitops.performSync(id: sync.id, envID: environmentID)
            if result.success {
                showToast(.success(sync.isBackup ? "Backup completed" : "Sync completed"))
            } else {
                showToast(.error(nonEmptyResourceValue(result.error) ?? result.message))
            }
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
        await reload()
        onChange()
    }

    private func deleteSync() async {
        guard let client = manager.client else { return }
        runningActionID = "delete"
        defer { runningActionID = nil }
        do {
            try await client.gitops.deleteSync(id: sync.id, envID: environmentID)
            showToast(.success(sync.isBackup ? "Backup stopped" : "Sync deleted"))
            onChange()
            dismiss()
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }
}

/// Loads the sync's project by ID, then shows the regular project page.
private struct GitOpsProjectDestination: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let projectID: String
    let environmentID: EnvironmentID

    @State private var project: ProjectDetails?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let project {
                ProjectDetailView(project: project, environmentID: environmentID)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Project Unavailable", systemImage: "square.stack.3d.up", description: Text(errorMessage))
            } else {
                ArcaneLoadingView("Loading project…")
            }
        }
        .task(id: manager.clientGeneration) {
            guard let client = manager.client else {
                errorMessage = "Connect to a server to continue."
                return
            }
            do {
                project = try await client.projects.get(envID: environmentID, projectID: projectID)
            } catch is CancellationError {
            } catch {
                errorMessage = friendlyErrorMessage(error)
            }
        }
    }
}
