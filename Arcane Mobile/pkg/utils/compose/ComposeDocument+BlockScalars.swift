import Foundation
import SwiftTreeSitter

nonisolated extension ComposeDocument {
    /// YAML 1.2 block scalar indentation, folding and chomping; never resolves interpolation.
    func blockScalar(_ node: Node) throws -> ComposeBlockScalar {
        guard node.nodeType == "block_scalar" else { throw ComposeDocumentError.unsupported }
        let bounds = range(node)
        let text = source as NSString
        let raw = substring(bounds).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let header = String(raw.prefix(while: { $0 != "\n" }))
        let indicator = String(header.prefix(while: { !$0.isWhitespace && $0 != "#" }))
        guard let style = indicator.first, style == "|" || style == ">" else { throw ComposeDocumentError.unsupported }
        let explicitIndent = indicator.compactMap(\.wholeNumberValue).first
        let headerSuffix = String(header.dropFirst(indicator.count))
        var parent = node.parent
        while let current = parent, !["block_mapping_pair", "block_sequence_item"].contains(current.nodeType ?? "") { parent = current.parent }
        let parentIndent = parent.map(column) ?? 0
        var extentEnd = NSMaxRange(bounds)
        // Tree-sitter excludes the final newline and chomped empty lines from clipped/stripped nodes.
        if extentEnd < text.length, text.character(at: extentEnd) == 13 { extentEnd += 1 }
        if extentEnd < text.length, text.character(at: extentEnd) == 10 { extentEnd += 1 }
        while extentEnd < text.length {
            var end = extentEnd
            while end < text.length && text.character(at: end) != 10 { end += 1 }
            if end < text.length { end += 1 }
            guard end > extentEnd else { break }
            let nextLine = substring(NSRange(location: extentEnd, length: end - extentEnd))
            guard nextLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
            extentEnd = end
        }
        let lexical = substring(NSRange(location: bounds.location, length: extentEnd - bounds.location))
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let body = lexical.firstIndex(of: "\n").map { String(lexical[lexical.index(after: $0)...]) } ?? ""
        let lines = body.components(separatedBy: "\n")
        let detected = lines.first(where: { $0.contains(where: { $0 != " " }) })?.prefix(while: { $0 == " " }).count
        let emptyIndentation = max(parentIndent + 1, lines.map { $0.prefix(while: { $0 == " " }).count }.max() ?? 0)
        let indentation = explicitIndent.map { parentIndent + $0 } ?? detected ?? emptyIndentation
        let content = lines.map { line -> String in
            let spaces = line.prefix(while: { $0 == " " }).count
            return String(line.dropFirst(min(spaces, indentation)))
        }
        var value = ""
        for index in content.indices {
            let line = content[index]
            value += line
            guard index + 1 < content.count else { continue }
            if style == "|" { value += "\n"; continue }
            let next = content[index + 1]
            let ordinary = !line.isEmpty && line.first != " " && line.first != "\t"
            if ordinary && !next.isEmpty && next.first != " " && next.first != "\t" {
                value += " "
            } else if ordinary && next.isEmpty,
                      let following = content.dropFirst(index + 1).first(where: { !$0.isEmpty }),
                      following.first != " " && following.first != "\t" {
                // The first break of a paragraph separator is folded away; the empty lines remain.
            } else {
                value += "\n"
            }
        }
        if !indicator.contains("+") {
            let hadFinalBreak = value.hasSuffix("\n")
            while value.hasSuffix("\n") { value.removeLast() }
            if !indicator.contains("-"), !value.isEmpty, hadFinalBreak { value += "\n" }
        }
        return ComposeBlockScalar(value: value, replacementRange: NSRange(location: bounds.location, length: extentEnd - bounds.location),
                                  indentation: indentation, parentIndentation: parentIndent, explicitIndentation: explicitIndent, headerSuffix: headerSuffix)
    }

    func replacingBlockScalar(_ block: ComposeBlockScalar, value: String) throws -> String {
        let replacement: String
        if value.unicodeScalars.contains(where: { $0.value == 13 || ($0.value < 32 && $0.value != 9 && $0.value != 10) }) {
            replacement = Self.quoted(value) + block.headerSuffix + newline
        } else {
            let trailingBreaks = value.reversed().prefix(while: { $0 == "\n" }).count
            let onlyBreaks = value.allSatisfy { $0 == "\n" }
            let chomp = trailingBreaks == 0 ? "-" : trailingBreaks > 1 || onlyBreaks ? "+" : ""
            var indentation = block.indentation
            var indicator = block.explicitIndentation.map(String.init) ?? ""
            let needsExplicitIndent = value.split(separator: "\n", omittingEmptySubsequences: false)
                .first(where: { !$0.isEmpty }).map { $0.first == " " || $0.first == "\t" } ?? false
            if needsExplicitIndent && indicator.isEmpty {
                let relative = indentation - block.parentIndentation
                if (1...9).contains(relative) { indicator = String(relative) }
                else { indicator = "2"; indentation = block.parentIndentation + 2 }
            }
            var lines = value.components(separatedBy: "\n")
            if value.hasSuffix("\n") { lines.removeLast() }
            if value.isEmpty { lines = [] }
            let padding = String(repeating: " ", count: indentation)
            let body = lines.map { $0.isEmpty ? "" : padding + $0 }.joined(separator: newline)
            // Literal style expresses the exact edited value without introducing new folding.
            replacement = "|" + indicator + chomp + block.headerSuffix + newline + (lines.isEmpty ? "" : body + newline)
        }
        let result = (source as NSString).replacingCharacters(in: block.replacementRange, with: replacement)
        _ = try ComposeDocument(result)
        return result
    }
}
