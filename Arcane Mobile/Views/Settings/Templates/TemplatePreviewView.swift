import SwiftUI
import Arcane

struct TemplatePreviewView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let template: Template

    @State private var downloadedTemplate: Template?
    @State private var content: TemplateContent?
    @State private var composeContent = ""
    @State private var envContent = ""
    @State private var selectedTab = 0
    @State private var isLoading = false
    @State private var isDownloading = false
    @State private var errorMessage: String?
    @State private var deployment: TemplateDeployment?

    private var displayedTemplate: Template {
        downloadedTemplate ?? content?.template ?? template
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

                    Picker("File", selection: $selectedTab) {
                        Text("compose.yml").tag(0)
                        Text(".env").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                    Divider()

                    if selectedTab == 0 {
                        CodeEditorView(text: $composeContent, language: .yaml)
                    } else {
                        CodeEditorView(text: $envContent, language: .env)
                    }
                }
            }
        }
        .navigationTitle(displayedTemplate.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if displayedTemplate.isRemote, canDownload {
                ToolbarItem(placement: .navigationBarTrailing) {
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

            if canDeploy {
                ToolbarItem(placement: .navigationBarTrailing) {
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
        .task(id: template.id) { await loadContent() }
    }

    private var canDownload: Bool {
        manager.permissions.has(Permission.Templates.read, in: nil)
    }

    private var canDeploy: Bool {
        manager.permissions.has(Permission.Projects.create, in: manager.activeEnvironmentID)
    }

    private func loadContent() async {
        guard let client = manager.client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let loaded = try await client.templates.getContent(id: displayedTemplate.id)
            content = loaded
            composeContent = loaded.content
            envContent = loaded.envContent
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func downloadTemplate() async {
        guard let client = manager.client, displayedTemplate.isRemote else { return }
        isDownloading = true
        defer { isDownloading = false }
        do {
            let downloaded = try await client.templates.download(id: displayedTemplate.id)
            let loaded = try await client.templates.getContent(id: downloaded.id)
            downloadedTemplate = loaded.template
            content = loaded
            composeContent = loaded.content
            envContent = loaded.envContent
            showToast(.success("Template downloaded"))
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
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
