import SwiftUI
import Arcane

struct GitRepositoriesView: View {
    var body: some View {
        DynamicResourceListView(
            title: "Git Repositories",
            systemImage: "arrow.triangle.branch",
            path: { _, _ in "customize/git-repositories" },
            emptyTitle: "No Git Repositories",
            actions: [
                .init(id: "test", title: "Test Connection", systemImage: "checkmark.seal", method: .post, pathSuffix: "/{id}/test"),
                .init(id: "delete", title: "Delete", systemImage: "trash", method: .delete, pathSuffix: "/{id}", destructive: true)
            ],
            createTitle: "Add Git Repository",
            createFields: [
                .init("name", label: "Name", required: true),
                .init("url", label: "URL", required: true, placeholder: "https://github.com/org/repo.git"),
                .init("branch", label: "Branch", placeholder: "main"),
                .init("username", label: "Username"),
                .init("token", label: "Token", type: .secure),
                .init("sshKey", label: "SSH Key", type: .multiline)
            ],
            createPath: { _, _ in "customize/git-repositories" }
        )
    }
}
