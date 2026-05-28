import SwiftUI
import Arcane

/// Hierarchical permission picker driven by the server's `PermissionsManifest`.
///
/// Composes one `Section(isExpanded:)` per resource into the surrounding Form
/// (each resource is a real Form row, not a sub-row inside a VStack — that's
/// what makes per-section expansion work). The parent owns the search text
/// (typically via `.searchable()`) and passes it in; when search is non-empty,
/// every matching resource auto-expands so the matches are visible.
struct PermissionPickerView: View {
    let manifest: PermissionsManifest
    @Binding var selected: Set<String>
    var isReadOnly: Bool = false
    let search: String

    @State private var expandedResources: Set<String> = []

    private var filteredResources: [PermissionResource] {
        if search.isEmpty { return manifest.resources }
        let q = search.lowercased()
        return manifest.resources.compactMap { resource in
            if resource.label.lowercased().contains(q) || resource.key.lowercased().contains(q) {
                return resource
            }
            let filtered = resource.actions.filter { action in
                action.label.lowercased().contains(q)
                    || action.permission.lowercased().contains(q)
                    || (action.description ?? "").lowercased().contains(q)
            }
            guard !filtered.isEmpty else { return nil }
            var copy = resource
            copy.actions = filtered
            return copy
        }
    }

    var body: some View {
        ForEach(filteredResources) { resource in
            Section {
                DisclosureGroup(isExpanded: expansionBinding(for: resource.key)) {
                    ForEach(resource.actions) { action in
                        actionToggle(action)
                    }
                } label: {
                    resourceHeader(resource)
                }
            }
        }
    }

    private func expansionBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { expandedResources.contains(key) || !search.isEmpty },
            set: { expanded in
                if expanded {
                    expandedResources.insert(key)
                } else {
                    expandedResources.remove(key)
                }
            }
        )
    }

    @ViewBuilder
    private func resourceHeader(_ resource: PermissionResource) -> some View {
        let actionsInResource = resource.actions
        let selectedCount = actionsInResource.filter { selected.contains($0.permission) }.count
        let totalCount = actionsInResource.count
        let allSelected = selectedCount == totalCount && totalCount > 0
        let partiallySelected = selectedCount > 0 && !allSelected

        HStack(spacing: 12) {
            Image(systemName: iconForResource(resource.key))
                .foregroundStyle(colorForResource(resource.key))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(resource.label)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    Text("\(selectedCount)/\(totalCount) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if resource.scopeKind == .global {
                        Text("· Global")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
            Button {
                if allSelected {
                    for a in actionsInResource { selected.remove(a.permission) }
                } else {
                    for a in actionsInResource { selected.insert(a.permission) }
                }
            } label: {
                Image(systemName: allSelected
                    ? "checkmark.square.fill"
                    : (partiallySelected ? "minus.square.fill" : "square"))
                    .font(.title3)
                    .foregroundStyle(allSelected || partiallySelected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(isReadOnly)
            .accessibilityLabel(allSelected ? "Deselect all in \(resource.label)" : "Select all in \(resource.label)")
        }
    }

    @ViewBuilder
    private func actionToggle(_ action: PermissionAction) -> some View {
        Toggle(isOn: Binding(
            get: { selected.contains(action.permission) },
            set: { isOn in
                if isOn { selected.insert(action.permission) }
                else { selected.remove(action.permission) }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.label.isEmpty ? action.key : action.label)
                    .font(.body)
                if let description = action.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(action.permission)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .disabled(isReadOnly)
    }

    private func iconForResource(_ key: String) -> String {
        switch key {
        case "containers": return "cube.box.fill"
        case "images": return "photo.stack.fill"
        case "projects": return "square.stack.3d.up.fill"
        case "volumes": return "externaldrive.fill"
        case "networks": return "network"
        case "swarm": return "square.stack.3d.up"
        case "users": return "person.2.fill"
        case "roles": return "person.crop.rectangle.stack.fill"
        case "apikeys": return "key.fill"
        case "settings": return "slider.horizontal.3"
        case "environments": return "server.rack"
        case "registries": return "shippingbox.fill"
        case "templates": return "doc.text.fill"
        case "git-repositories": return "arrow.triangle.branch"
        case "gitops": return "arrow.triangle.merge"
        case "webhooks": return "link.badge.plus"
        case "system": return "gearshape.fill"
        case "vulnerabilities": return "ladybug.fill"
        case "image-updates": return "arrow.triangle.2.circlepath"
        case "events": return "clock.badge.exclamationmark"
        case "dashboard": return "chart.bar.fill"
        case "jobs": return "calendar.badge.clock"
        case "notifications": return "bell.badge.fill"
        case "customize": return "paintbrush.fill"
        case "build-workspaces": return "hammer.fill"
        default: return "lock.fill"
        }
    }

    private func colorForResource(_ key: String) -> Color {
        switch key {
        case "containers", "images", "projects", "users", "authentication": return .blue
        case "volumes": return .orange
        case "networks": return .teal
        case "swarm": return .mint
        case "registries": return .purple
        case "templates", "git-repositories", "gitops": return .indigo
        case "webhooks": return .green
        case "system", "settings": return .gray
        case "vulnerabilities": return .red
        case "roles": return .purple
        case "apikeys": return .yellow
        case "events": return .red
        case "jobs": return .pink
        default: return .secondary
        }
    }
}
