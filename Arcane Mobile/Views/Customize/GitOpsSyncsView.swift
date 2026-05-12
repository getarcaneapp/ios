import SwiftUI
import Arcane

struct GitOpsSyncsView: View {
    let environmentID: EnvironmentID

    var body: some View {
        DynamicResourceListView(
            title: "GitOps",
            systemImage: "arrow.triangle.branch",
            path: { _, client in client.rest.environmentPath(environmentID, "gitops-syncs") },
            emptyTitle: "No GitOps Syncs",
            actions: [
                .init(id: "sync", title: "Sync Now", systemImage: "arrow.clockwise", method: .post, pathSuffix: "/{id}/sync"),
                .init(id: "delete", title: "Delete", systemImage: "trash", method: .delete, pathSuffix: "/{id}", destructive: true)
            ],
            createTitle: "Create GitOps Sync",
            createFields: [
                .init("name", label: "Name", required: true),
                .init("repositoryId", label: "Repository ID", required: true),
                .init("branch", label: "Branch", placeholder: "main"),
                .init("path", label: "Path", required: true),
                .init("enabled", label: "Enabled", type: .toggle)
            ],
            createPath: { _, client in client.rest.environmentPath(environmentID, "gitops-syncs") }
        )
    }
}
