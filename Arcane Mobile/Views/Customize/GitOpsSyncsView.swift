import Arcane
import SwiftUI

struct GitOpsSyncsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager

    let environmentID: EnvironmentID
    /// All Environments preview: list and act on resources from every enabled environment.
    var allEnvironments = false

    var body: some View {
        DynamicResourceListView(
            title: "GitOps",
            systemImage: "arrow.triangle.branch",
            path: { environmentID, client in client.rest.environmentPath(environmentID, "gitops-syncs") },
            environmentID: environmentID,
            allEnvironments: allEnvironments,
            emptyTitle: "No GitOps Syncs",
            actions: [
                .init(
                    id: "sync", title: "Sync Now", systemImage: "arrow.clockwise", method: .post,
                    pathSuffix: "/{id}/sync"),
                .init(
                    id: "delete", title: "Delete", systemImage: "trash", method: .delete, pathSuffix: "/{id}",
                    destructive: true),
            ],
            createTitle: "Create GitOps Sync",
            createFields: [
                .init("name", label: "Name", required: true),
                .init("repositoryId", label: "Repository ID", required: true),
                .init("branch", label: "Branch", placeholder: "main"),
                .init("composePath", label: "Compose Path", required: true, placeholder: "compose.yaml"),
                .init("autoSync", label: "Auto Sync", type: .toggle),
            ],
            createPath: { environmentID, client in client.rest.environmentPath(environmentID, "gitops-syncs") },
            managementDestination: manager.canAccess(.gitRepositories) ? .gitRepositories : nil,
            detailDestination: { item, onChange in
                AnyView(
                    GitOpsSyncDetailView(
                        sync: GitOpsSyncDetails(resource: item.value),
                        environmentID: item.environmentID,
                        onChange: onChange
                    ))
            }
        )
    }
}
