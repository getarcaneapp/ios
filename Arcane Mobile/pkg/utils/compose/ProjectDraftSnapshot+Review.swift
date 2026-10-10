import Foundation
import SwiftTreeSitter
import TreeSitterYAML

nonisolated extension ProjectDraftSnapshot {
    func serviceChanges(from original: ProjectDraftSnapshot) -> [String] {
        guard let after = try? ComposeDocument(compose) else { return [] }
        let before = try? ComposeDocument(original.compose)
        let oldServices = Set(before?.services ?? [])
        let newServices = Set(after.services)
        return oldServices.union(newServices).sorted().flatMap { service -> [String] in
            if !oldServices.contains(service) { return ["Added service: \(service)"] }
            if !newServices.contains(service) { return ["Removed service: \(service)"] }
            let path = ["services", service]
            let keys = Set(before?.keys(at: path) ?? []).union(after.keys(at: path))
            return keys.sorted().compactMap { key in
                before?.rawValue(at: path + [key]) != after.rawValue(at: path + [key])
                    ? "\(service): \(key) changed" : nil
            }
        }
    }

    func sourceDiff(from original: ProjectDraftSnapshot) -> String {
        let before = original.compose.components(separatedBy: "\n")
        let after = compose.components(separatedBy: "\n")
        let difference = after.difference(from: before)
        let removed = difference.removals.compactMap { change -> Int? in
            if case .remove(let offset, _, _) = change { return offset }
            return nil
        }
        let inserted = difference.insertions.compactMap { change -> Int? in
            if case .insert(let offset, _, _) = change { return offset }
            return nil
        }
        return
            (removed.sorted().map { "- \(before[$0])" }
            + inserted.sorted().map { "+ \(after[$0])" }).joined(separator: "\n")
    }

    /// Checks syntax only: valid advanced YAML remains saveable through the raw editor.
    func validateSyntax() throws {
        let parser = Parser()
        try parser.setLanguage(tree_sitter_yaml())
        guard let root = parser.parse(compose)?.rootNode, !root.hasError else {
            throw ComposeDocumentError.invalid("Invalid YAML. Correct the Compose source before saving.")
        }
    }

    func canApplyLoadedContent(requestedFrom snapshot: ProjectDraftSnapshot, session: String, currentSession: String)
        -> Bool
    {
        self == snapshot && session == currentSession
    }
}
