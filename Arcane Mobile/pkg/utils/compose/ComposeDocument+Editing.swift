import Foundation
import SwiftTreeSitter

nonisolated extension ComposeDocument {
    func setting(_ value: String, at path: [String]) throws -> String {
        guard let key = path.last else { throw ComposeDocumentError.unsupported }
        try validateFragment(value)
        let parentPath = Array(path.dropLast())
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var nested = value
            for key in path.reversed() { nested = entry(key, value: nested, indent: 0) }
            return try replace(NSRange(location: 0, length: (source as NSString).length), with: nested + newline)
        }
        _ = try editableTarget(parentPath, inspectChildren: false)
        if let node = resolve(path) {
            _ = try editableTarget(path)
            if value == fragment(node) { return source }
            // Avoid changing spelling, comments, or quoting on an unchanged form value.
            if Self.isScalar(node), Self.decode(value) == Self.decode(fragment(node)) { return source }
            let replacementDocument = try ComposeDocument(value)
            let isBlock = Self.mapping(replacementDocument.root) != nil || Self.sequence(replacementDocument.root) != nil
            if isBlock && Self.mapping(node) == nil && Self.sequence(node) == nil {
                let pairColumn = node.parent.map(column) ?? 0
                return try replace(range(node), with: newline + String(repeating: " ", count: pairColumn + 2) + reindent(value, column: pairColumn + 2))
            }
            return try replace(range(node), with: reindent(value, column: column(node)))
        }
        guard let parent = resolve(parentPath), let mapping = Self.mapping(parent) else {
            // Create missing ancestor mappings, using the same source-range insertion path.
            if !parentPath.isEmpty, resolve(parentPath) == nil {
                return try setting(entry(key, value: value, indent: 0), at: parentPath)
            }
            if let parent = resolve(parentPath), fragment(parent) == "{}" {
                let pair = parent.parent ?? parent
                return try expandingEmptyMapping(pair, removing: range(parent), key: key, value: value)
            }
            if parentPath.isEmpty, source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return try replace(NSRange(location: 0, length: (source as NSString).length), with: entry(key, value: value, indent: 0) + newline)
            }
            throw ComposeDocumentError.unsupported
        }
        let entries = pairs(mapping)
        if let emptyPair = entries.first(where: { $0.child(byFieldName: "key").flatMap { Self.decode(fragment($0)) } == key }) {
            return try expandingEmptyMapping(emptyPair, removing: nil, key: key, value: value, nested: false)
        }
        guard let last = entries.last else { throw ComposeDocumentError.unsupported }
        let insertion = lineEnd(NSMaxRange(range(last)))
        let prefix = insertion > 0 && !substring(NSRange(location: insertion - 1, length: 1)).contains("\n") ? newline : ""
        return try replace(NSRange(location: insertion, length: 0), with: prefix + entry(key, value: value, indent: column(last)) + newline)
    }

    func removing(at path: [String]) throws -> String {
        guard let key = path.last, let parent = resolve(Array(path.dropLast())), let mapping = Self.mapping(parent) else { throw ComposeDocumentError.missing }
        _ = try editableTarget(path)
        guard let pair = pairs(mapping).first(where: { $0.child(byFieldName: "key").flatMap { Self.decode(fragment($0)) } == key }) else { throw ComposeDocumentError.missing }
        if pairs(mapping).count == 1 {
            // An empty mapping stays a mapping rather than changing to YAML null.
            return try replace(range(mapping), with: "{}")
        }
        return try replace(fullLines(pair), with: "")
    }

    func settingItem(_ rawValue: String, at path: [String], index: Int) throws -> String {
        if let node = resolve(path), let sequence = Self.flowSequence(node) {
            _ = try editableTarget(path)
            let items = Self.flowItems(sequence)
            guard items.indices.contains(index) else { throw ComposeDocumentError.missing }
            try validateFlowItem(rawValue)
            return try replace(range(items[index]), with: rawValue)
        }
        let item = try sequenceItem(path, index: index)
        guard let content = Self.content(item) else { throw ComposeDocumentError.unsupported }
        try validateFragment(rawValue)
        return try replace(range(content), with: reindent(rawValue, column: column(content)))
    }

    func removingItem(at path: [String], index: Int) throws -> String {
        if let node = resolve(path), let sequence = Self.flowSequence(node) {
            _ = try editableTarget(path)
            let items = Self.flowItems(sequence)
            guard items.indices.contains(index) else { throw ComposeDocumentError.missing }
            let commas = flowCommas(sequence)
            // Delete syntax tokens only, retaining surrounding whitespace and comments.
            let itemRange = range(items[index])
            let comma = commas.first { range($0).location >= NSMaxRange(itemRange) }
                ?? commas.last { NSMaxRange(range($0)) <= itemRange.location }
            var ranges = [itemRange]
            if let comma { ranges.append(range(comma)) }
            if items.count == 1 { ranges += commas.filter { range($0) != comma.map(range) }.map(range) }
            var result = source as NSString
            for bounds in ranges.sorted(by: { $0.location > $1.location }) {
                result = result.replacingCharacters(in: bounds, with: "") as NSString
            }
            _ = try ComposeDocument(result as String)
            return result as String
        }
        let item = try sequenceItem(path, index: index)
        if items(at: path)?.count == 1, let node = resolve(path) { return try replace(range(node), with: "[]") }
        return try replace(fullLines(item), with: "")
    }

    func appendingItem(_ rawValue: String, at path: [String]) throws -> String {
        try validateFragment(rawValue)
        guard let node = resolve(path) else { return try setting("- " + rawValue, at: path) }
        if let sequence = Self.flowSequence(node) {
            _ = try editableTarget(path)
            try validateFlowItem(rawValue)
            let items = Self.flowItems(sequence)
            let close = NSMaxRange(range(sequence)) - 1
            var result = (source as NSString).replacingCharacters(in: NSRange(location: close, length: 0), with: (items.isEmpty ? "" : " ") + rawValue)
            if let last = items.last, !flowCommas(sequence).contains(where: { range($0).location >= NSMaxRange(range(last)) }) {
                result = (result as NSString).replacingCharacters(in: NSRange(location: NSMaxRange(range(last)), length: 0), with: ",")
            }
            _ = try ComposeDocument(result)
            return result
        }
        _ = try editableTarget(path)
        guard let sequence = Self.sequence(node), let last = Self.children(sequence).last(where: { $0.nodeType == "block_sequence_item" }) else { throw ComposeDocumentError.unsupported }
        let insertion = lineEnd(NSMaxRange(range(last)))
        let indent = column(last)
        let prefix = insertion > 0 && !substring(NSRange(location: insertion - 1, length: 1)).contains("\n") ? newline : ""
        return try replace(NSRange(location: insertion, length: 0), with: prefix + String(repeating: " ", count: indent) + "- " + reindent(rawValue, column: indent + 2) + newline)
    }

    private func expandingEmptyMapping(_ pair: Node, removing bounds: NSRange?, key: String, value: String, nested: Bool = true) throws -> String {
        let insertion = lineEnd(NSMaxRange(range(pair)))
        let prefix = insertion > 0 && !substring(NSRange(location: insertion - 1, length: 1)).contains("\n") ? newline : ""
        let text: String
        if nested {
            text = entry(key, value: value, indent: column(pair) + 2)
        } else {
            // The requested key is the existing null entry; add its value below its original line.
            text = String(repeating: " ", count: column(pair) + 2) + reindent(value, column: column(pair) + 2)
        }
        var result = (source as NSString).replacingCharacters(in: NSRange(location: insertion, length: 0), with: prefix + text + newline)
        if let bounds { result = (result as NSString).replacingCharacters(in: bounds, with: "") }
        _ = try ComposeDocument(result)
        return result
    }

    private func validateFlowItem(_ value: String) throws {
        let document = try ComposeDocument("[" + value + "]")
        guard let sequence = Self.flowSequence(document.root), Self.flowItems(sequence).count == 1,
              let item = Self.flowItems(sequence).first, Self.isScalar(item),
              document.isEditable(at: []), document.fragment(item) == value,
              !value.contains("\n"), !value.contains("\r") else { throw ComposeDocumentError.unsupported }
    }

    private func sequenceItem(_ path: [String], index: Int) throws -> Node {
        _ = try editableTarget(path)
        guard let node = resolve(path), let sequence = Self.sequence(node) else { throw ComposeDocumentError.unsupported }
        let items = Self.children(sequence).filter { $0.nodeType == "block_sequence_item" }
        guard items.indices.contains(index) else { throw ComposeDocumentError.missing }
        return items[index]
    }

    private func entry(_ key: String, value: String, indent: Int) -> String {
        let padding = String(repeating: " ", count: indent)
        let document = try? ComposeDocument(value)
        let block = document.map { Self.mapping($0.root) != nil || Self.sequence($0.root) != nil } ?? false
        if block || value.contains("\n") || value.hasPrefix("- ") {
            return padding + Self.quoted(key) + ":" + newline + String(repeating: " ", count: indent + 2) + reindent(value, column: indent + 2)
        }
        return padding + Self.quoted(key) + ": " + value
    }

    private func validateFragment(_ value: String) throws {
        let document = try ComposeDocument(value)
        guard Self.content(document.root) != nil else { throw ComposeDocumentError.invalid("Enter a YAML value.") }
    }

    private func replace(_ range: NSRange, with replacement: String) throws -> String {
        let result = (source as NSString).replacingCharacters(in: range, with: replacement)
        _ = try ComposeDocument(result)
        return result
    }

    private func reindent(_ value: String, column: Int) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").enumerated().map { index, line in
            index == 0 || line.isEmpty ? line : String(repeating: " ", count: column) + line
        }.joined(separator: newline)
    }

    private func fullLines(_ node: Node) -> NSRange {
        let bounds = range(node)
        let start = lineStart(bounds.location)
        return NSRange(location: start, length: lineEnd(NSMaxRange(bounds)) - start)
    }
}
