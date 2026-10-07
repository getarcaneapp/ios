import Foundation
import SwiftTreeSitter

nonisolated extension ComposeDocument {
    var newline: String { source.contains("\r\n") ? "\r\n" : "\n" }
    func range(_ node: Node) -> NSRange {
        NSRange(location: Int(node.byteRange.lowerBound / 2), length: Int((node.byteRange.upperBound - node.byteRange.lowerBound) / 2))
    }
    func substring(_ range: NSRange) -> String { (source as NSString).substring(with: range) }
    func fragment(_ node: Node) -> String {
        let text = substring(range(node))
        let indent = column(node)
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        return lines.enumerated().map { index, line in
            guard index > 0 else { return line }
            return String(line.dropFirst(min(indent, line.prefix(while: { $0 == " " }).count)))
        }.joined(separator: "\n")
    }
    func lineStart(_ offset: Int) -> Int {
        let text = source as NSString
        var position = offset
        while position > 0 && text.character(at: position - 1) != 10 { position -= 1 }
        return position
    }
    func lineEnd(_ offset: Int) -> Int {
        let text = source as NSString
        if offset > 0 && text.character(at: offset - 1) == 10 { return offset }
        var position = offset
        while position < text.length && text.character(at: position) != 10 { position += 1 }
        return position < text.length ? position + 1 : position
    }
    func column(_ node: Node) -> Int { range(node).location - lineStart(range(node).location) }
    static func children(_ node: Node) -> [Node] { (0..<node.namedChildCount).compactMap { node.namedChild(at: $0) } }
    static func firstError(_ node: Node) -> Node {
        for child in children(node) where child.hasError || child.isMissing { return firstError(child) }
        return node
    }
    static func content(_ node: Node) -> Node? {
        if ["stream", "document", "block_node", "flow_node", "block_sequence_item"].contains(node.nodeType ?? "") {
            return children(node).first(where: { !["comment", "anchor", "tag", "yaml_directive", "tag_directive"].contains($0.nodeType ?? "") }).flatMap(content)
        }
        return node
    }
    static func mapping(_ node: Node) -> Node? { content(node).flatMap { $0.nodeType == "block_mapping" ? $0 : nil } }
    static func sequence(_ node: Node) -> Node? { content(node).flatMap { $0.nodeType == "block_sequence" ? $0 : nil } }
    static func flowSequence(_ node: Node) -> Node? { content(node).flatMap { $0.nodeType == "flow_sequence" ? $0 : nil } }
    static func flowItems(_ node: Node) -> [Node] { children(node).filter { $0.nodeType != "comment" } }
    func flowCommas(_ node: Node) -> [Node] {
        (0..<node.childCount).compactMap { node.child(at: $0) }.filter { $0.nodeType == "," }
    }
    static func isScalar(_ node: Node) -> Bool {
        guard let content = content(node) else { return false }
        return ["plain_scalar", "double_quote_scalar", "single_quote_scalar"].contains(content.nodeType ?? "")
    }
    static func decode(_ value: String) -> String? {
        if value.hasPrefix("\"") { return value.data(using: .utf8).flatMap { try? JSONDecoder().decode(String.self, from: $0) } }
        if value.hasPrefix("'"), value.hasSuffix("'") { return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
        return value
    }
    func pairs(_ mapping: Node) -> [Node] { Self.children(mapping).filter { ["block_mapping_pair", "flow_pair"].contains($0.nodeType ?? "") || mapping.nodeType == "flow_mapping" && $0.nodeType == "flow_node" } }
    func resolve(_ path: [String]) -> Node? {
        var node = Self.content(root)
        for key in path {
            guard let current = node, let mapping = Self.mapping(current), let pair = pairs(mapping).first(where: {
                $0.child(byFieldName: "key").flatMap { Self.decode(fragment($0)) } == key
            }) else { return nil }
            node = pair.child(byFieldName: "value")
        }
        return node
    }
    func editableTarget(_ path: [String], inspectChildren: Bool = true) throws -> Node {
        var node = Self.content(root) ?? root
        for key in path {
            guard !hasDecoration(node) else { throw ComposeDocumentError.unsupported }
            if Self.content(node)?.nodeType == "flow_mapping", fragment(node) == "{}" { return node }
            guard let mapping = Self.mapping(node) else { throw ComposeDocumentError.unsupported }
            guard !pairs(mapping).contains(where: { $0.child(byFieldName: "key").map { fragment($0) == "<<" } ?? false }) else { throw ComposeDocumentError.unsupported }
            guard let pair = pairs(mapping).first(where: { $0.child(byFieldName: "key").flatMap { Self.decode(fragment($0)) } == key }), let value = pair.child(byFieldName: "value") else { return node }
            node = value
        }
        if hasDecoration(node) { throw ComposeDocumentError.unsupported }
        if let mapping = Self.mapping(node), pairs(mapping).contains(where: { $0.child(byFieldName: "key").map { fragment($0) == "<<" } ?? false }) { throw ComposeDocumentError.unsupported }
        if inspectChildren && containsUnsupported(node) { throw ComposeDocumentError.unsupported }
        return node
    }
    private func hasDecoration(_ node: Node) -> Bool {
        if ["anchor", "alias", "tag"].contains(node.nodeType ?? "") { return true }
        return ["block_node", "flow_node"].contains(node.nodeType ?? "") && Self.children(node).contains { ["anchor", "alias", "tag"].contains($0.nodeType ?? "") }
    }
    private func containsUnsupported(_ node: Node) -> Bool {
        if hasDecoration(node) { return true }
        if node.nodeType == "flow_mapping" { return fragment(node) != "{}" }
        if node.nodeType == "flow_sequence" {
            return Self.flowItems(node).contains { !Self.isScalar($0) || containsUnsupported($0) }
        }
        if node.nodeType == "block_mapping_pair", let key = node.child(byFieldName: "key"), fragment(key) == "<<" { return true }
        return Self.children(node).contains(where: containsUnsupported)
    }
    func validateKeys(_ node: Node) throws {
        if ["block_mapping", "flow_mapping"].contains(node.nodeType ?? "") {
            var seen: Set<String> = []
            for pair in pairs(node) {
                guard let key = pair.child(byFieldName: "key") ?? (pair.nodeType == "flow_node" ? pair : nil), Self.isScalar(key), let decoded = Self.decode(fragment(key)) else { continue }
                guard seen.insert(decoded).inserted else { throw ComposeDocumentError.invalid("Duplicate YAML key: \(decoded).") }
            }
        }
        for child in Self.children(node) { try validateKeys(child) }
    }
}
