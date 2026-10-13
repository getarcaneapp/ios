import Arcane
import SwiftUI

struct GitRepositoriesView: View {
    /// Fields accepted by both the create and update requests; the server
    /// rejects unknown keys.
    private static let fields: [BackendFormField] = [
        .init("name", label: "Name", required: true),
        .init("url", label: "URL", required: true, placeholder: "https://github.com/org/repo.git"),
        .init("authType", label: "Authentication", type: .choice(["none", "http", "ssh"])),
        .init("username", label: "Username"),
        .init("token", label: "Token", type: .secure),
        .init("sshKey", label: "SSH Key", type: .multiline),
        .init("description", label: "Description"),
    ]

    var body: some View {
        DynamicResourceListView(
            title: "Git Repositories",
            systemImage: "arrow.triangle.branch",
            path: { _, _ in "customize/git-repositories" },
            emptyTitle: "No Git Repositories",
            actions: [
                .init(
                    id: "test", title: "Test Connection", systemImage: "checkmark.seal", method: .post,
                    pathSuffix: "/{id}/test"),
                .init(
                    id: "delete", title: "Delete", systemImage: "trash", method: .delete, pathSuffix: "/{id}",
                    destructive: true),
            ],
            createTitle: "Add Git Repository",
            createFields: Self.fields,
            createPath: { _, _ in "customize/git-repositories" },
            edit: DynamicEditConfig(title: "Edit Git Repository", fields: Self.fields)
        )
    }
}
