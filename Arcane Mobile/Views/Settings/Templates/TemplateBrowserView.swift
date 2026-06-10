import SwiftUI
import Arcane

struct TemplateBrowserView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var templates: [Template] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var groupedTemplates: [(String, [Template])] {
        let groups = Dictionary(grouping: templates) { template in
            template.registry?.name ?? (template.isRemote ? "Remote" : "Local")
        }
        return groups.keys.sorted().map { key in
            let sorted = (groups[key] ?? []).sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return (key, sorted)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && templates.isEmpty {
                    ProgressView("Loading templates...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage, templates.isEmpty {
                    ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                } else if templates.isEmpty {
                    ContentUnavailableView("No Templates", systemImage: "doc.text", description: nil)
                } else {
                    List {
                        ForEach(groupedTemplates, id: \.0) { registryName, templates in
                            Section(registryName) {
                                ForEach(templates) { template in
                                    NavigationLink(destination: TemplatePreviewView(template: template)) {
                                        TemplateRow(template: template)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { Task { await loadTemplates() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task { await loadTemplates() }
            .refreshable { await loadTemplates() }
        }
    }

    private func loadTemplates() async {
        guard let client = manager.client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            templates = try await client.rest.get("templates/all")
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

struct TemplateRow: View {
    let template: Template

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: template.iconUrl, size: 36) {
                Image(systemName: template.isRemote ? "cloud.fill" : "doc.text.fill")
                    .font(.title3)
                    .foregroundStyle(template.isRemote ? .blue : .indigo)
                    .frame(width: 36, height: 36)
                    .glassEffectCompat(in: .circle)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(template.name)
                    .font(.headline)
                Text(template.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

