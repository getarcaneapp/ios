import Arcane
import SwiftUI

/// Attach, detach, and create project tags. Each change is a single
/// `PATCH projects/{id}/tags` call; tags declared in the compose file are
/// shown but locked.
struct ProjectTagsSheet: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let projectID: String
    let environmentID: EnvironmentID
    let onChange: ([ProjectTag]) -> Void

    @State private var tags: [ProjectTag]
    @State private var catalog: [ProjectTagOption] = []
    @State private var newName = ""
    @State private var newColor = "blue"
    @State private var pendingName: String?
    @State private var errorMessage: String?

    init(
        projectID: String,
        environmentID: EnvironmentID,
        tags: [ProjectTag],
        onChange: @escaping ([ProjectTag]) -> Void
    ) {
        self.projectID = projectID
        self.environmentID = environmentID
        self.onChange = onChange
        _tags = State(initialValue: tags)
    }

    /// Attached tags first, then unattached catalog tags.
    private var rows: [ProjectTag] {
        let attachedNames = Set(tags.map(\.name))
        let unattached =
            catalog
            .filter { !attachedNames.contains($0.name) }
            .map(\.asTag)
        return tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            + unattached.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var trimmedNewName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !rows.isEmpty {
                    Section {
                        ForEach(rows, id: \.name) { tag in
                            tagRow(tag)
                        }
                    } header: {
                        Text("Tags")
                    } footer: {
                        if tags.contains(where: \.isComposeManaged) {
                            Text("Locked tags come from the compose file.")
                        }
                    }
                }
                Section("New Tag") {
                    FormTextField(
                        title: "Name",
                        placeholder: "production",
                        text: $newName,
                        autocapitalization: .never,
                        autocorrectionDisabled: true
                    )
                    colorPicker
                    Button {
                        Task { await setTag(trimmedNewName, attached: true, color: newColor) }
                    } label: {
                        Label("Add Tag", systemImage: "plus")
                    }
                    .disabled(trimmedNewName.isEmpty || pendingName != nil)
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadCatalog() }
        }
    }

    private func tagRow(_ tag: ProjectTag) -> some View {
        let attached = tags.contains { $0.name == tag.name }
        return Button {
            Task { await setTag(tag.name, attached: !attached, color: tag.color) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "tag.fill")
                    .foregroundStyle(tag.displayColor)
                Text(verbatim: tag.name)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if pendingName == tag.name {
                    ProgressView().controlSize(.small)
                } else if tag.isComposeManaged {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Managed by compose file")
                } else if attached {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .disabled(tag.isComposeManaged || pendingName != nil)
    }

    private var colorPicker: some View {
        HStack(spacing: 10) {
            ForEach(ProjectTag.availableColors, id: \.self) { color in
                Button {
                    newColor = color
                } label: {
                    Circle()
                        .fill(ProjectTag.displayColor(for: color))
                        .frame(width: 24, height: 24)
                        .overlay {
                            if newColor == color {
                                Image(systemName: "checkmark")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(color.capitalized)
                .accessibilityAddTraits(newColor == color ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    private func loadCatalog() async {
        guard let client = manager.client else { return }
        let path = client.rest.environmentPath(environmentID, "projects/tags")
        catalog = (try? await client.rest.get(path)) ?? []
    }

    private func setTag(_ name: String, attached: Bool, color: String?) async {
        guard let client = manager.client, !name.isEmpty else { return }
        pendingName = name
        errorMessage = nil
        defer { pendingName = nil }
        do {
            let path = client.rest.environmentPath(
                environmentID, "projects/\(ArcaneAPIHelpers.escapedPathComponent(projectID))/tags")
            let response: UpdateProjectTagResponse = try await client.rest.patch(
                path, body: UpdateProjectTagRequest(name: name, attached: attached, color: color))
            tags = response.tags ?? []
            if attached, name == trimmedNewName { newName = "" }
            if attached, !catalog.contains(where: { $0.name == name }), let color {
                catalog.append(ProjectTagOption(name: name, color: color))
            }
            onChange(tags)
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
