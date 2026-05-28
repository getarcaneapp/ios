import SwiftUI
import Arcane

extension Role {
    /// Display name shown in UI. Falls back to the role ID.
    var displayName: String { name.isEmpty ? id : name }

    /// SF Symbol selected based on the role ID. Built-ins get distinctive
    /// icons; custom roles fall back to a generic shield.
    var systemImage: String {
        switch id {
        case Role.BuiltIn.admin: return "lock.shield.fill"
        case Role.BuiltIn.editor, Role.BuiltIn.noShellEditor: return "pencil.circle.fill"
        case Role.BuiltIn.deployer: return "shippingbox.fill"
        case Role.BuiltIn.monitor: return "eye.fill"
        case Role.BuiltIn.viewer: return "doc.text.fill"
        default: return "person.crop.rectangle.fill"
        }
    }

    var iconColor: Color {
        switch id {
        case Role.BuiltIn.admin: return .indigo
        case Role.BuiltIn.editor, Role.BuiltIn.noShellEditor: return .blue
        case Role.BuiltIn.deployer: return .orange
        case Role.BuiltIn.monitor: return .teal
        case Role.BuiltIn.viewer: return .gray
        default: return .purple
        }
    }
}

extension RoleAssignmentSummary: @retroactive Identifiable {
    public var id: String {
        // roleId + environmentId scope is unique per user — works as an
        // identifier within a single user's assignment list.
        if let env = environmentId { return "\(roleId)#\(env)" }
        return "\(roleId)#global"
    }
}

/// Renders a one-line summary of a permission resource scope.
func displayScopeLabel(for environmentId: String?, environments: [Arcane.Environment]) -> String {
    guard let environmentId else { return "Global" }
    if let env = environments.first(where: { $0.id == environmentId }) {
        return env.name ?? "Environment \(environmentId)"
    }
    return "Environment \(environmentId)"
}

/// Format the v2 API's validation error map ("field: message") into a single
/// readable string for inline display.
func formatValidationFields(_ fields: [String: [String]]) -> String {
    fields
        .sorted { $0.key < $1.key }
        .map { key, messages in "\(key): \(messages.joined(separator: ", "))" }
        .joined(separator: "\n")
}
