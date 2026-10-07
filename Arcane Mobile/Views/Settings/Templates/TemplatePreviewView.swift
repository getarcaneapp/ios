import SwiftUI
import Arcane

struct TemplatePreviewView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let template: Template
    var onChange: () async -> Void = {}

    @State private var downloadedTemplate: Template?
    @State private var content: TemplateContent?
    @State private var composeContent = ""
    @State private var envContent = ""
    @State private var selectedTab = 0
    @State private var isLoading = false
    @State private var isDownloading = false
    @State private var errorMessage: String?
    @State private var deployment: TemplateDeployment?
    @State private var editorMode: TemplateEditorMode?
    @State private var confirmDelete = false
    @State private var isDeleting = false
    @State private var loadedSessionIdentity: String?

    private var displayedTemplate: Template {
        content?.template ?? downloadedTemplate ?? template
    }

    var body: some View {
        Group {
            if isLoading && content == nil {
                ProgressView("Loading template…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, content == nil {
                ContentUnavailableView {
                    Label("Couldn't Load Template", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { Task { await loadContent() } }
                }
            } else if let content {
                VStack(spacing: 0) {
                    TemplateContentSummary(template: displayedTemplate, content: content)

                    ScrollableTabBar(
                        selection: $selectedTab,
                        options: [
                            ScrollableTabOption(
                                0,
                                title: "compose.yml",
                                systemImage: "doc.text.fill",
                                tint: .blue
                            ),
                            ScrollableTabOption(
                                1,
                                title: ".env",
                                systemImage: "key.fill",
                                tint: .orange
                            )
                        ],
                        accessibilityLabel: "Template files"
                    )

                    if selectedTab == 0 {
                        CodeEditorView(text: $composeContent, language: .yaml, readOnly: true)
                    } else {
                        CodeEditorView(text: $envContent, language: .env, readOnly: true)
                    }
                }
            }
        }
        .navigationTitle(displayedTemplate.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !displayedTemplate.isRemote && (canEdit || canDelete) {
                AppToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        if canEdit {
                            Button("Edit Template", systemImage: "pencil") { editorMode = .edit(displayedTemplate) }
                        }
                        if canDelete {
                            Button("Delete Template", systemImage: "trash", role: .destructive) { confirmDelete = true }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .disabled(content == nil || isDeleting)
                    .accessibilityLabel("Template Actions")
                }
            }
            if displayedTemplate.isRemote, canDownload {
                AppToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await downloadTemplate() }
                    } label: {
                        if isDownloading {
                            ProgressView()
                        } else {
                            Label("Download", systemImage: "arrow.down.circle")
                        }
                    }
                    .disabled(isDownloading)
                    .accessibilityLabel(isDownloading ? "Downloading template" : "Download template")
                }
            }

            if #available(iOS 26, *),
               displayedTemplate.isRemote,
               canDownload,
               canDeploy {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }

            if canDeploy {
                AppToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        guard let content else { return }
                        deployment = TemplateDeployment(template: displayedTemplate, content: content)
                    } label: {
                        Label("Deploy", systemImage: "play.circle.fill")
                    }
                    .disabled(content == nil || isDownloading)
                }
            }
        }
        .sheet(item: $editorMode) { mode in
            TemplateEditorView(mode: mode) {
                await loadContent()
                await onChange()
            }
        }
        .confirmationDialog("Delete this local template?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Template", role: .destructive) { Task { await deleteTemplate() } }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $deployment) { deployment in
            CreateProjectView(
                environmentID: manager.activeEnvironmentID,
                prefilledName: deployment.template.name
                    .lowercased()
                    .replacingOccurrences(of: " ", with: "-"),
                prefilledCompose: deployment.content.content,
                prefilledEnv: deployment.content.envContent,
                templateLabel: deployment.template.name
            ) {
                self.deployment = nil
                dismiss()
            }
        }
        .task(id: "\(template.id)|\(manager.cacheSessionIdentity)") { await loadContent() }
    }

    private var canEdit: Bool {
        loadedSessionIdentity == manager.cacheSessionIdentity
            && manager.permissions.has(Permission.Templates.read, in: nil)
            && manager.permissions.has(Permission.Templates.update, in: nil)
    }

    private var canDelete: Bool {
        loadedSessionIdentity == manager.cacheSessionIdentity
            && manager.permissions.has(Permission.Templates.delete, in: nil)
    }

    private func deleteTemplate() async {
        guard let client = manager.client, !displayedTemplate.isRemote, canDelete, !isDeleting else { return }
        let identity = manager.cacheSessionIdentity
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await client.templates.delete(id: displayedTemplate.id)
            guard identity == manager.cacheSessionIdentity else { return }
            showToast(.success("Template deleted"))
            await onChange()
            dismiss()
        } catch { showToast(.error(friendlyErrorMessage(error))) }
    }

    private var canDownload: Bool {
        loadedSessionIdentity == manager.cacheSessionIdentity
            && manager.permissions.has(Permission.Templates.read, in: nil)
    }

    private var canDeploy: Bool {
        loadedSessionIdentity == manager.cacheSessionIdentity
            && manager.permissions.has(Permission.Projects.create, in: manager.activeEnvironmentID)
    }

    private func loadContent() async {
        guard let client = manager.client else { return }
        let identity = manager.cacheSessionIdentity
        if loadedSessionIdentity != identity {
            content = nil
            downloadedTemplate = nil
            composeContent = ""
            envContent = ""
        }
        guard manager.permissions.has(Permission.Templates.read, in: nil) else {
            errorMessage = "Your role cannot read templates."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let loaded = try await loadBoundedContent(client: client, id: displayedTemplate.id)
            guard identity == manager.cacheSessionIdentity else { return }
            loadedSessionIdentity = identity
            content = loaded
            composeContent = loaded.content
            envContent = loaded.envContent
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func downloadTemplate() async {
        guard let client = manager.client, displayedTemplate.isRemote, canDownload else { return }
        let identity = manager.cacheSessionIdentity
        isDownloading = true
        defer { isDownloading = false }
        do {
            let downloaded = try await client.templates.download(id: displayedTemplate.id)
            let loaded = try await loadBoundedContent(client: client, id: downloaded.id)
            guard identity == manager.cacheSessionIdentity else { return }
            downloadedTemplate = loaded.template
            content = loaded
            composeContent = loaded.content
            envContent = loaded.envContent
            showToast(.success("Template downloaded"))
            await onChange()
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }

    private func loadBoundedContent(client: ArcaneClient, id: String) async throws -> TemplateContent {
        let escapedID = ArcaneAPIHelpers.escapedPathComponent(id)
        return try await RemoteDataLimits.boundedAPIResponse(
            client: client,
            path: "templates/\(escapedID)/content",
            as: TemplateContent.self,
            maximumBytes: RemoteDataLimits.maximumTemplateBytes
        )
    }
}

private struct TemplateDeployment: Identifiable {
    let template: Template
    let content: TemplateContent

    var id: String { template.id }
}

private struct TemplateContentSummary: View {
    let template: Template
    let content: TemplateContent

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TemplateSummaryBadge(
                        title: template.isRemote ? "Remote" : "Local",
                        icon: template.isRemote ? "cloud.fill" : "internaldrive.fill",
                        tint: template.isRemote ? .blue : .indigo
                    )

                    if let author = template.metadata?.author, !author.isEmpty {
                        TemplateSummaryBadge(title: author, icon: "person.fill", tint: .secondary)
                    }
                    if let version = template.metadata?.version, !version.isEmpty {
                        TemplateSummaryBadge(title: version, icon: "tag.fill", tint: .secondary)
                    }
                    if let tags = template.metadata?.tags {
                        ForEach(tags.prefix(3), id: \.self) { tag in
                            TemplateSummaryBadge(title: tag, icon: "number", tint: .secondary)
                        }
                    }

                    TemplateSummaryBadge(
                        title: "\(content.services.count) service\(content.services.count == 1 ? "" : "s")",
                        icon: "shippingbox.fill",
                        tint: .purple
                    )
                    TemplateSummaryBadge(
                        title: "\(content.envVariables.count) variable\(content.envVariables.count == 1 ? "" : "s")",
                        icon: "curlybraces",
                        tint: .orange
                    )
                }

                if !content.services.isEmpty {
                    Text("Services: \(content.services.joined(separator: ", "))")
                        .lineLimit(1)
                }
                if !content.envVariables.isEmpty {
                    Text("Variables: \(content.envVariables.map(\.key).joined(separator: ", "))")
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.top, 10)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let source = template.isRemote ? "Remote" : "Local"
        return "\(source) template. \(content.services.count) services. \(content.envVariables.count) environment variables."
    }
}

private struct TemplateSummaryBadge: View {
    let title: String
    let icon: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: Radius.nested, style: .continuous)
            )
    }
}
