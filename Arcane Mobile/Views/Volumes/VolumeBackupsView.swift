import SwiftUI
import Arcane

struct VolumeBackupsView: View {
    let environmentID: EnvironmentID
    let volumeName: String

    var body: some View {
        DynamicResourceListView(
            title: "Backups",
            systemImage: "externaldrive.badge.timemachine",
            path: { _, client in
                client.rest.environmentPath(environmentID, "volumes/\(ArcaneAPIHelpers.escapedPathComponent(volumeName))/backups")
            },
            actions: [
                .init(id: "restore", title: "Restore", systemImage: "arrow.counterclockwise", method: .post, pathSuffix: "/{id}/restore"),
                .init(id: "delete", title: "Delete", systemImage: "trash", method: .delete, pathSuffix: "/{id}", destructive: true)
            ]
        )
    }
}
