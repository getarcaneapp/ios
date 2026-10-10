import Foundation
import SwiftTreeSitter
import TreeSitterYAML

/// A source-backed YAML document. Edits replace syntax ranges, never serialize the document.
nonisolated struct ComposeDocument {
    let source: String
    let root: Node

    init(_ source: String) throws {
        let parser = Parser()
        try parser.setLanguage(tree_sitter_yaml())
        guard let root = parser.parse(source)?.rootNode else {
            throw ComposeDocumentError.invalid("Unable to parse YAML.")
        }
        guard !root.hasError else {
            let error = Self.firstError(root)
            let line = Int(error.pointRange.lowerBound.row) + 1
            throw ComposeDocumentError.invalid("Invalid YAML at line \(line).")
        }
        self.source = source
        self.root = root
        let documents = Self.children(root).filter { $0.nodeType == "document" }
        guard documents.count <= 1 else {
            throw ComposeDocumentError.invalid("Edit multi-document YAML in the YAML editor.")
        }
        try validateKeys(root)
    }

    var services: [String] {
        let path: [ComposeFieldPathComponent] = [.key("services")]
        guard nativeField(at: path).kind == .mapping else { return [] }
        return nativeFields(at: path).map(\.name).filter { $0 != "<<" }
    }

    func rawValue(at path: [String]) -> String? { resolve(path).map { fragment($0) } }
    func scalar(at path: [String]) -> String? {
        guard let node = resolve(path), Self.isScalar(node) else { return nil }
        return Self.decode(fragment(node))
    }
    func value(at path: [String]) -> String? { scalar(at: path) ?? rawValue(at: path) }
    func keys(at path: [String]) -> [String] {
        guard let node = resolve(path), let mapping = Self.mapping(node) else { return [] }
        return pairs(mapping).compactMap { $0.child(byFieldName: "key").flatMap { Self.decode(fragment($0)) } }
    }
    func items(at path: [String]) -> [String]? {
        guard let node = resolve(path) else { return nil }
        if let sequence = Self.flowSequence(node) { return Self.flowItems(sequence).map(fragment) }
        guard let sequence = Self.sequence(node) else { return nil }
        return Self.children(sequence).filter { $0.nodeType == "block_sequence_item" }.compactMap {
            Self.content($0).map(fragment)
        }
    }
    func isEditable(at path: [String]) -> Bool { (try? editableTarget(path)) != nil }

    static func quoted(_ string: String) -> String {
        guard let data = try? JSONEncoder().encode(string), let result = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return result.replacingOccurrences(of: "\\/", with: "/")
    }
}

nonisolated enum ComposeDocumentError: LocalizedError {
    case invalid(String)
    case unsupported
    case missing

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .unsupported: return "This YAML structure must be edited in the YAML editor."
        case .missing: return "This field no longer exists. Reopen the editor and try again."
        }
    }
}
