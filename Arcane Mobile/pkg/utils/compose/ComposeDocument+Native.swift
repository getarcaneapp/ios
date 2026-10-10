import Foundation
import SwiftTreeSitter

nonisolated extension ComposeDocument {
    func nativeField(at path: [ComposeFieldPathComponent], name: String = "Value") -> ComposeNativeField {
        do {
            guard let node = try nativeNode(path) else {
                return ComposeNativeField(name: name, path: path, kind: .null, value: "")
            }
            guard !nativeUnsafe(node), let content = Self.content(node) else { throw ComposeDocumentError.unsupported }
            let kind: ComposeNativeKind
            let value: String
            switch content.nodeType {
            case "block_mapping", "flow_mapping":
                kind = .mapping
                value = ""
            case "block_sequence", "flow_sequence":
                kind = .sequence
                value = ""
            case "plain_scalar":
                switch Self.children(content).first?.nodeType {
                case "boolean_scalar": kind = .boolean
                case "integer_scalar", "float_scalar": kind = .number
                case "null_scalar": kind = .null
                default: kind = .string
                }
                value = fragment(content)
            case "block_scalar":
                kind = .string
                value = try blockScalar(content).value
            case "double_quote_scalar", "single_quote_scalar":
                guard let decoded = Self.decode(fragment(content)), !fragment(content).contains("\n") else {
                    throw ComposeDocumentError.unsupported
                }
                kind = .string
                value = decoded
            default: throw ComposeDocumentError.unsupported
            }
            if content.nodeType == "plain_scalar", value.contains("\n") { throw ComposeDocumentError.unsupported }
            return ComposeNativeField(name: name, path: path, kind: kind, value: value)
        } catch {
            return ComposeNativeField(name: name, path: path, kind: .unsupported, value: "")
        }
    }

    func nativeFields(at path: [ComposeFieldPathComponent]) -> [ComposeNativeField] {
        guard let node = try? nativeNode(path), !nativeUnsafe(node), let content = Self.content(node) else { return [] }
        if nativeMapping(content) {
            return nativePairs(content).compactMap { pair in
                guard let name = nativeKey(pair) else { return nil }
                return nativeField(at: path + [.key(name)], name: name)
            }
        }
        if nativeSequence(content) {
            return nativeItems(content).indices.map { nativeField(at: path + [.index($0)], name: "Item \($0 + 1)") }
        }
        return []
    }

    static func nativeLiteral(kind: ComposeNativeKind, value: String) throws -> String {
        switch kind {
        case .string: return quoted(value)
        case .boolean: return value.lowercased() == "true" ? "true" : "false"
        case .null: return "null"
        case .mapping: return "{}"
        case .sequence: return "[]"
        case .number:
            let parsed = try ComposeDocument(value)
            guard parsed.nativeField(at: []).kind == .number, parsed.rawValue(at: []) == value, !value.contains("\n"),
                !value.contains("\r"), value == value.trimmingCharacters(in: .whitespaces)
            else {
                throw ComposeFormError.invalid("Enter a valid number.")
            }
            return value
        case .unsupported: throw ComposeDocumentError.unsupported
        }
    }

    func settingNative(_ value: String, kind: ComposeNativeKind, at path: [ComposeFieldPathComponent]) throws -> String
    {
        let literal = try Self.nativeLiteral(kind: kind, value: value)
        if kind == .null, try nativeNode(path) == nil, nativeEntryExists(path) { return source }
        if let node = try nativeNode(path) {
            guard !nativeUnsafe(node), let content = Self.content(node), !nativeContainsReferences(content) else {
                throw ComposeDocumentError.unsupported
            }
            let current = nativeField(at: path)
            if current.kind == kind && (current.value == value || kind == .null) { return source }
            if nativeHasAnchor(node), current.kind != kind || kind == .mapping || kind == .sequence {
                throw ComposeDocumentError.unsupported
            }
            if content.nodeType == "block_scalar", kind == .string {
                let result = try replacingBlockScalar(blockScalar(content), value: value)
                guard try ComposeDocument(result).nativeField(at: path).value == value else {
                    throw ComposeDocumentError.unsupported
                }
                return result
            }
            if content.nodeType == "block_scalar" {
                let block = try blockScalar(content)
                return try nativeApplying([(block.replacementRange, literal + block.headerSuffix + newline)])
            }
            return try nativeApplying([(range(content), literal)])
        }
        guard let last = path.last else {
            let prefix = source.isEmpty || source.hasSuffix("\n") || source.hasSuffix("\r\n") ? "" : newline
            return try nativeApplying([
                (NSRange(location: (source as NSString).length, length: 0), prefix + literal + newline)
            ])
        }
        let parentPath = Array(path.dropLast())
        guard let parent = try nativeNode(parentPath), let content = Self.content(parent), !nativeUnsafe(parent) else {
            // Native callers can create a missing object a field at a time.
            if case .key(let key) = last {
                let parentSource = try settingNative("", kind: .mapping, at: parentPath)
                return try ComposeDocument(parentSource).settingNative(value, kind: kind, at: parentPath + [.key(key)])
            }
            throw ComposeDocumentError.unsupported
        }
        if case .key = last, nativeField(at: parentPath).kind == .null {
            let expanded = try settingNative("", kind: .mapping, at: parentPath)
            return try ComposeDocument(expanded).settingNative(value, kind: kind, at: path)
        }
        if case .key(let key) = last, nativeMapping(content) {
            let pairs = nativePairs(content)
            if let pair = pairs.first(where: { nativeKey($0) == key }) {
                if pair.nodeType == "flow_node" {
                    return try nativeApplying([(NSRange(location: NSMaxRange(range(pair)), length: 0), ": " + literal)])
                }
                guard
                    let colon = (0..<pair.childCount).compactMap({ pair.child(at: $0) }).first(where: {
                        $0.nodeType == ":"
                    })
                else { throw ComposeDocumentError.unsupported }
                return try nativeApplying([(NSRange(location: NSMaxRange(range(colon)), length: 0), " " + literal)])
            }
            return try nativeAppend(key: key, literal: literal, container: content)
        }
        if case .index(let index) = last, nativeSequence(content) {
            let items = nativeItems(content)
            guard items.indices.contains(index) else { throw ComposeDocumentError.missing }
            let item = items[index]
            return try nativeApplying([(NSRange(location: NSMaxRange(range(item)), length: 0), " " + literal)])
        }
        throw ComposeDocumentError.unsupported
    }

    func addingService(_ name: String, field: String, value: String, kind: ComposeNativeKind) throws -> String {
        guard name.range(of: #"^[a-zA-Z0-9._-]+$"#, options: .regularExpression) != nil else {
            throw ComposeFormError.invalid("Use letters, numbers, dots, underscores or hyphens for the service name.")
        }
        guard !field.isEmpty else { throw ComposeFormError.invalid("Enter a field name.") }
        let added = try addingNative("", kind: .mapping, key: name, at: [.key("services")])
        return try ComposeDocument(added).addingNative(
            value, kind: kind, key: field, at: [.key("services"), .key(name)])
    }

    func addingNative(_ value: String, kind: ComposeNativeKind, key: String?, at path: [ComposeFieldPathComponent])
        throws -> String
    {
        let literal = try Self.nativeLiteral(kind: kind, value: value)
        guard let node = try nativeNode(path), let content = Self.content(node) else {
            guard let key else { throw ComposeDocumentError.unsupported }
            return try settingNative(value, kind: kind, at: path + [.key(key)])
        }
        guard !nativeUnsafe(node) else { throw ComposeDocumentError.unsupported }
        if nativeField(at: path).kind == .null, key != nil {
            let expanded = try settingNative("", kind: .mapping, at: path)
            return try ComposeDocument(expanded).addingNative(value, kind: kind, key: key, at: path)
        }
        if nativeMapping(content) {
            guard let key, !key.isEmpty else { throw ComposeFormError.invalid("Enter a field name.") }
            guard key != "<<" else { throw ComposeDocumentError.unsupported }
            guard !nativePairs(content).contains(where: { nativeKey($0) == key }) else {
                throw ComposeFormError.duplicate
            }
            return try nativeAppend(key: key, literal: literal, container: content)
        }
        if nativeSequence(content) { return try nativeAppend(key: nil, literal: literal, container: content) }
        throw ComposeDocumentError.unsupported
    }

    func removingNative(at path: [ComposeFieldPathComponent]) throws -> String {
        guard let last = path.last, let parent = try nativeNode(Array(path.dropLast())),
            let container = Self.content(parent), !nativeUnsafe(parent)
        else { throw ComposeDocumentError.unsupported }
        let entries: [Node]
        let target: Node
        switch last {
        case .key(let key):
            guard key != "<<" else { throw ComposeDocumentError.unsupported }
            entries = nativePairs(container)
            guard let pair = entries.first(where: { nativeKey($0) == key }) else { throw ComposeDocumentError.missing }
            target = pair
        case .index(let index):
            entries = nativeItems(container)
            guard entries.indices.contains(index) else { throw ComposeDocumentError.missing }
            target = entries[index]
        }
        // Refuse deleting anchors or aliases; their references can exist outside this subtree.
        guard !nativeContainsReferences(target) else { throw ComposeDocumentError.unsupported }
        if container.nodeType?.hasPrefix("flow_") == true {
            var edits = [(range(target), "")]
            let commas = flowCommas(container)
            let comma =
                commas.first { range($0).location >= NSMaxRange(range(target)) }
                ?? commas.last { NSMaxRange(range($0)) <= range(target).location }
            if let comma { edits.append((range(comma), "")) }
            return try nativeApplying(edits)
        }
        if entries.count == 1 {
            // Keep comments from the removed subtree as comments adjacent to the empty container.
            let replacement = nativeMapping(container) ? "{}" : "[]"
            let comments = nativeComments(target).map { substring(range($0)) }
            let suffix =
                comments.isEmpty
                ? "" : " " + comments.joined(separator: newline + String(repeating: " ", count: column(container)))
            return try nativeApplying([(range(container), replacement + suffix)])
        }
        let bounds = range(target)
        let start = lineStart(bounds.location)
        let end = lineEnd(NSMaxRange(bounds))
        let comments = nativeComments(target).map {
            String(repeating: " ", count: column(target)) + substring(range($0)) + newline
        }.joined()
        let prefix = substring(NSRange(location: start, length: bounds.location - start))
        if !prefix.trimmingCharacters(in: .whitespaces).isEmpty {
            // A compact mapping/list can share its first line with an outer sequence dash.
            // Retain that dash and leave the remaining children on their indented lines.
            let trailing = substring(NSRange(location: NSMaxRange(bounds), length: end - NSMaxRange(bounds)))
            let comment =
                trailing.firstIndex(of: "#").map { String(trailing[$0...]).trimmingCharacters(in: .newlines) } ?? ""
            return try nativeApplying([
                (NSRange(location: bounds.location, length: end - bounds.location), comment + newline + comments)
            ])
        }
        return try nativeApplying([(NSRange(location: start, length: end - start), comments)])
    }

    private func nativeAppend(key: String?, literal: String, container: Node) throws -> String {
        let entries = nativeMapping(container) ? nativePairs(container) : nativeItems(container)
        let text = key.map { Self.quoted($0) + ": " + literal } ?? literal
        if container.nodeType?.hasPrefix("flow_") == true {
            let close = NSMaxRange(range(container)) - 1
            var edits: [(NSRange, String)] = [
                (NSRange(location: close, length: 0), (entries.isEmpty ? "" : " ") + text)
            ]
            if let last = entries.last,
                !flowCommas(container).contains(where: { range($0).location >= NSMaxRange(range(last)) })
            {
                edits.append((NSRange(location: NSMaxRange(range(last)), length: 0), ","))
            }
            return try nativeApplying(edits)
        }
        guard let last = entries.last else { throw ComposeDocumentError.unsupported }
        let insertion = lineEnd(NSMaxRange(range(last)))
        let prefix = insertion > 0 && substring(NSRange(location: insertion - 1, length: 1)) == "\n" ? "" : newline
        let row = String(repeating: " ", count: column(last)) + (key == nil ? "- " : "") + text + newline
        return try nativeApplying([(NSRange(location: insertion, length: 0), prefix + row)])
    }

    private func nativeNode(_ path: [ComposeFieldPathComponent]) throws -> Node? {
        var node = Self.content(root)
        for component in path {
            guard let current = node else { return nil }
            guard !nativeUnsafe(current), let content = Self.content(current) else {
                throw ComposeDocumentError.unsupported
            }
            switch component {
            case .key(let key):
                guard key != "<<" else { throw ComposeDocumentError.unsupported }
                if content.nodeType == "plain_scalar", Self.children(content).first?.nodeType == "null_scalar" {
                    return nil
                }
                guard nativeMapping(content) else { throw ComposeDocumentError.unsupported }
                node = nativePairs(content).first(where: { nativeKey($0) == key })?.child(byFieldName: "value")
            case .index(let index):
                guard nativeSequence(content) else { throw ComposeDocumentError.unsupported }
                let items = nativeItems(content)
                guard items.indices.contains(index) else { throw ComposeDocumentError.missing }
                node = content.nodeType == "flow_sequence" ? items[index] : Self.content(items[index])
            }
        }
        return node
    }

    private func nativeEntryExists(_ path: [ComposeFieldPathComponent]) -> Bool {
        guard let last = path.last, let parent = try? nativeNode(Array(path.dropLast())),
            let content = Self.content(parent)
        else { return false }
        switch last {
        case .key(let key): return nativePairs(content).contains { nativeKey($0) == key }
        case .index(let index): return nativeItems(content).indices.contains(index)
        }
    }

    private func nativeMapping(_ node: Node) -> Bool {
        ["block_mapping", "flow_mapping"].contains(node.nodeType ?? "")
    }
    private func nativeSequence(_ node: Node) -> Bool {
        ["block_sequence", "flow_sequence"].contains(node.nodeType ?? "")
    }
    private func nativePairs(_ node: Node) -> [Node] {
        Self.children(node).filter {
            ["block_mapping_pair", "flow_pair"].contains($0.nodeType ?? "")
                || node.nodeType == "flow_mapping" && $0.nodeType == "flow_node"
        }
    }
    private func nativeItems(_ node: Node) -> [Node] { Self.children(node).filter { $0.nodeType != "comment" } }
    private func nativeKey(_ pair: Node) -> String? {
        let key = pair.child(byFieldName: "key") ?? (pair.nodeType == "flow_node" ? pair : nil)
        return key.flatMap { Self.decode(fragment($0)) }
    }

    private func nativeUnsafe(_ node: Node) -> Bool {
        if node.nodeType == "alias" || nativeUnsupportedTag(node) { return true }
        if ["block_node", "flow_node"].contains(node.nodeType ?? ""),
            Self.children(node).contains(where: { $0.nodeType == "alias" || nativeUnsupportedTag($0) })
        {
            return true
        }
        if let parent = node.parent, ["block_node", "flow_node"].contains(parent.nodeType ?? ""),
            Self.children(parent).contains(where: nativeUnsupportedTag)
        {
            return true
        }
        guard let content = Self.content(node) else { return false }
        if nativeMapping(content) {
            let entries = nativePairs(content)
            if Self.children(content).contains(where: {
                !["comment", "block_mapping_pair", "flow_pair", "flow_node"].contains($0.nodeType ?? "")
            }) {
                return true
            }
            return entries.contains { pair in
                guard let key = pair.child(byFieldName: "key") ?? (pair.nodeType == "flow_node" ? pair : nil),
                    Self.isScalar(key), nativeKey(pair) != nil
                else { return true }
                return fragment(key).contains("\n")
                    || Self.children(key).contains { ["anchor", "alias", "tag"].contains($0.nodeType ?? "") }
            }
        }
        return false
    }

    private func nativeUnsupportedTag(_ node: Node) -> Bool {
        node.nodeType == "tag" && !["!reset", "!override"].contains(fragment(node))
    }

    private func nativeHasAnchor(_ node: Node) -> Bool {
        if Self.children(node).contains(where: { $0.nodeType == "anchor" }) { return true }
        if let parent = node.parent, ["block_node", "flow_node"].contains(parent.nodeType ?? "") {
            return Self.children(parent).contains(where: { $0.nodeType == "anchor" })
        }
        return false
    }

    private func nativeContainsReferences(_ node: Node) -> Bool {
        ["anchor", "alias", "tag"].contains(node.nodeType ?? "")
            || Self.children(node).contains(where: nativeContainsReferences)
    }
    private func nativeComments(_ node: Node) -> [Node] {
        if node.nodeType == "comment" { return [node] }
        return Self.children(node).flatMap(nativeComments)
    }
    private func nativeApplying(_ edits: [(NSRange, String)]) throws -> String {
        var result = source as NSString
        for (bounds, replacement) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            result = result.replacingCharacters(in: bounds, with: replacement) as NSString
        }
        _ = try ComposeDocument(result as String)
        return result as String
    }
}
