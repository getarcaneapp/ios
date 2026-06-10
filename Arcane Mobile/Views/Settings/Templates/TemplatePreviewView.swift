import SwiftUI
import Arcane

struct TemplatePreviewView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let template: Template

    @State private var content: TemplateContent?
    @State private var composeContent = ""
    @State private var envContent = ""
    @State private var selectedTab = 0
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showDeploy = false

    var body: some View {
        Group {
            if isLoading && content == nil {
                ProgressView("Loading template...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
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
        .navigationTitle(template.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showDeploy = true
                } label: {
                    Label("Deploy", systemImage: "play.circle.fill")
                }
                .disabled(content == nil)
            }
        }
        .sheet(isPresented: $showDeploy) {
            CreateProjectView(
                environmentID: manager.activeEnvironmentID,
                prefilledName: template.name
                    .lowercased()
                    .replacingOccurrences(of: " ", with: "-"),
                prefilledCompose: composeContent,
                prefilledEnv: envContent,
                templateLabel: template.name
            ) {
                showDeploy = false
                dismiss()
            }
        }
        .task { await loadContent() }
        .overlay(alignment: .bottom) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding()
            }
        }
    }

    private func loadContent() async {
        guard let client = manager.client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let loaded: TemplateContent = try await client.rest.get("templates/\(template.id)/content")
            content = loaded
            composeContent = loaded.content
            envContent = loaded.envContent
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

