import Foundation
import SwiftTreeSitter

nonisolated extension ComposeDocument {
    /// Converts only attachment syntax, keeping each name, comment and surrounding source in place.
    func convertingNetworkAttachments(at path: [String]) throws -> String {
        guard let node = resolve(path) else { return source }
        if ["block_mapping", "flow_mapping"].contains(Self.content(node)?.nodeType ?? "") { return source }
        _ = try editableTarget(path)
        if let sequence = Self.flowSequence(node) {
            var pair: Node? = node
            while let current = pair, current.nodeType != "block_mapping_pair" {
                if current.nodeType == "flow_pair" { throw ComposeDocumentError.unsupported }
                pair = current.parent
            }
            guard let pair else { throw ComposeDocumentError.unsupported }
            let items = Self.flowItems(sequence)
            var names = Set<String>()
            let indent = String(repeating: " ", count: column(pair) + 2)
            let comments = Self.children(sequence).filter { $0.nodeType == "comment" }
            var rows: [String] = []
            for comment in comments where items.first.map({ range(comment).location < range($0).location }) ?? true {
                rows.append(indent + substring(range(comment)))
            }
            for (index, item) in items.enumerated() {
                guard Self.isScalar(item), let name = Self.decode(fragment(item)), !name.isEmpty, names.insert(name).inserted else { throw ComposeDocumentError.unsupported }
                var row = indent + Self.quoted(name) + ": {}"
                let next = index + 1 < items.count ? range(items[index + 1]).location : NSMaxRange(range(sequence))
                let attached = comments.filter { range($0).location >= NSMaxRange(range(item)) && range($0).location < next }
                if let first = attached.first { row += " " + substring(range(first)) }
                rows.append(row)
                rows += attached.dropFirst().map { indent + substring(range($0)) }
            }
            if items.isEmpty {
                let result = (source as NSString).replacingCharacters(in: range(sequence), with: "{}")
                _ = try ComposeDocument(result)
                return result
            }
            // Keep the attachment key's trailing comment on its original line.
            let insertion = lineEnd(NSMaxRange(range(pair)))
            let prefix = insertion > 0 && substring(NSRange(location: insertion - 1, length: 1)) == "\n" ? "" : newline
            var result = (source as NSString).replacingCharacters(in: NSRange(location: insertion, length: 0), with: prefix + rows.joined(separator: newline) + newline)
            result = (result as NSString).replacingCharacters(in: range(sequence), with: "")
            _ = try ComposeDocument(result)
            return result
        }
        var edits: [(NSRange, String)] = []
        let entries: [Node]
        let isFlow = Self.flowSequence(node) != nil
        if let sequence = Self.flowSequence(node) {
            entries = Self.flowItems(sequence)
            let bounds = range(sequence)
            edits.append((NSRange(location: bounds.location, length: 1), "{"))
            edits.append((NSRange(location: NSMaxRange(bounds) - 1, length: 1), "}"))
        } else if let sequence = Self.sequence(node) {
            entries = Self.children(sequence).filter { $0.nodeType == "block_sequence_item" }
        } else { throw ComposeDocumentError.unsupported }
        var names = Set<String>()
        for item in entries {
            guard let content = Self.content(item), Self.isScalar(content), let name = Self.decode(fragment(content)), !name.isEmpty,
                  names.insert(name).inserted else { throw ComposeDocumentError.unsupported }
            let bounds = range(item)
            let contentBounds = range(content)
            let replacementRange = isFlow ? contentBounds : NSRange(location: bounds.location, length: NSMaxRange(contentBounds) - bounds.location)
            edits.append((replacementRange, Self.quoted(name) + ": {}"))
        }
        var result = source as NSString
        for (bounds, replacement) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            result = result.replacingCharacters(in: bounds, with: replacement) as NSString
        }
        _ = try ComposeDocument(result as String)
        return result as String
    }
}
