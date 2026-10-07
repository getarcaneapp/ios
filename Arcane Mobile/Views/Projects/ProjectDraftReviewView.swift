import SwiftUI

/// Reviews source changes without resolving variables or interpreting secret values.
struct ProjectDraftReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let originalCompose: String
    let compose: String
    let environmentChanged: Bool
    var additionalChanges: [String] = []
    var saveTitle = "Save"
    var canDeploy = false
    let save: (Bool) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Changes") {
                    if originalCompose != compose {
                        Label("Compose configuration changed", systemImage: "doc.text")
                    }
                    ForEach(serviceChanges, id: \.self) { Text($0).font(.subheadline) }
                    if environmentChanged {
                        Label("Environment variables changed", systemImage: "key")
                    }
                    ForEach(Array(Set(additionalChanges)).sorted(), id: \.self) { Text($0) }
                }
                if originalCompose != compose {
                    Section {
                        DisclosureGroup("YAML Diff") {
                            Text("This diff may contain sensitive values.")
                                .font(.caption).foregroundStyle(.secondary)
                            ScrollView(.horizontal) {
                                Text(verbatim: sourceDiff)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                Section {
                    Button(saveTitle) { dismiss(); save(false) }
                    if canDeploy {
                        Button("Save and deploy") { dismiss(); save(true) }
                    }
                } footer: {
                    Text("Saving stores your files. Deployment is a separate operation.")
                }
            }
            .navigationTitle("Review Changes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private var draft: ProjectDraftSnapshot { .init(compose: compose, environment: "") }
    private var original: ProjectDraftSnapshot { .init(compose: originalCompose, environment: "") }
    private var serviceChanges: [String] { draft.serviceChanges(from: original) }
    private var sourceDiff: String { draft.sourceDiff(from: original) }
}
