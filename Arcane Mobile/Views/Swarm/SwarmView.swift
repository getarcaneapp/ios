import SwiftUI
import Arcane

struct SwarmView: View {
    let environmentID: EnvironmentID

    var body: some View {
        List {
            Section("Cluster") {
                swarmLink("Status", icon: "checkmark.seal", suffix: "status")
                swarmLink("Info", icon: "info.circle", suffix: "info")
                swarmLink("Join Tokens", icon: "key", suffix: "join-tokens")
                RunEndpointButton(title: "Initialize Swarm", systemImage: "plus.circle", path: { client in client.rest.environmentPath(environmentID, "swarm/init") })
                RunEndpointButton(title: "Leave Swarm", systemImage: "rectangle.portrait.and.arrow.right", path: { client in client.rest.environmentPath(environmentID, "swarm/leave") }, destructive: true)
            }
            Section("Resources") {
                swarmListLink("Services", icon: "square.stack.3d.up", suffix: "services", actions: [
                    .init(id: "scale", title: "Scale", systemImage: "arrow.up.and.down", method: .post, pathSuffix: "/{id}/scale"),
                    .init(id: "rollback", title: "Rollback", systemImage: "arrow.uturn.backward", method: .post, pathSuffix: "/{id}/rollback"),
                    .init(id: "delete", title: "Delete", systemImage: "trash", method: .delete, pathSuffix: "/{id}", destructive: true)
                ])
                swarmListLink("Nodes", icon: "server.rack", suffix: "nodes", actions: [
                    .init(id: "promote", title: "Promote", systemImage: "arrow.up.circle", method: .post, pathSuffix: "/{id}/promote"),
                    .init(id: "demote", title: "Demote", systemImage: "arrow.down.circle", method: .post, pathSuffix: "/{id}/demote"),
                    .init(id: "delete", title: "Delete", systemImage: "trash", method: .delete, pathSuffix: "/{id}", destructive: true)
                ])
                swarmListLink("Tasks", icon: "list.bullet.rectangle", suffix: "tasks")
                swarmListLink("Stacks", icon: "square.stack.3d.up.fill", suffix: "stacks", actions: [
                    .init(id: "delete", title: "Delete", systemImage: "trash", method: .delete, pathSuffix: "/{id}", destructive: true)
                ])
                swarmListLink("Configs", icon: "doc.badge.gearshape", suffix: "configs", actions: [
                    .init(id: "delete", title: "Delete", systemImage: "trash", method: .delete, pathSuffix: "/{id}", destructive: true)
                ])
                swarmListLink("Secrets", icon: "lock.doc", suffix: "secrets", actions: [
                    .init(id: "delete", title: "Delete", systemImage: "trash", method: .delete, pathSuffix: "/{id}", destructive: true)
                ])
            }
        }
        .navigationTitle("Swarm")
    }

    private func swarmLink(_ title: String, icon: String, suffix: String) -> some View {
        NavigationLink {
            DynamicResourceListView(
                title: title,
                systemImage: icon,
                path: { _, client in client.rest.environmentPath(environmentID, "swarm/\(suffix)") }
            )
        } label: {
            Label(title, systemImage: icon)
        }
    }

    private func swarmListLink(_ title: String, icon: String, suffix: String, actions: [BackendListAction] = []) -> some View {
        NavigationLink {
            DynamicResourceListView(
                title: title,
                systemImage: icon,
                path: { _, client in client.rest.environmentPath(environmentID, "swarm/\(suffix)") },
                actions: actions
            )
        } label: {
            Label(title, systemImage: icon)
        }
    }
}
