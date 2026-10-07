import Foundation

nonisolated struct EnvEntry: Identifiable {
    var id: Int { line }
    let line: Int
    let name: String
    let value: String
    let range: NSRange
}

nonisolated struct EnvDocument {
    let source: String
    let entries: [EnvEntry]
    let unsupportedLines: Int

    init(_ source: String) {
        self.source = source
        var entries: [EnvEntry] = []
        var unsupported = 0
        var assignmentNames: [String] = []
        let ns = source as NSString
        var offset = 0
        var lineNumber = 0
        var multilineQuote: Character?
        while offset < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: offset, length: 0))
            let raw = ns.substring(with: lineRange)
            let line = raw.trimmingCharacters(in: .newlines)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { offset = NSMaxRange(lineRange); lineNumber += 1 }
            if let quote = multilineQuote {
                unsupported += 1
                if Self.hasClosingQuote(in: line[...], quote: quote) { multilineQuote = nil }
                continue
            }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let regex = try? NSRegularExpression(pattern: #"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$"#),
                  let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { unsupported += 1; continue }
            let name = (line as NSString).substring(with: match.range(at: 1))
            assignmentNames.append(name)
            let value = (line as NSString).substring(with: match.range(at: 2))
            let decoded: String
            if value.hasPrefix("'") || value.hasPrefix("\"") {
                let quote = value.first!
                guard Self.hasClosingQuote(in: value.dropFirst(), quote: quote) else {
                    unsupported += 1
                    multilineQuote = quote
                    continue
                }
                guard value.count >= 2, value.last == quote else {
                    unsupported += 1
                    if !Self.hasClosingQuote(in: value.dropFirst(), quote: quote) { multilineQuote = quote }
                    continue
                }
                guard !value.dropFirst().dropLast().contains(quote), !value.contains("\\") else { unsupported += 1; continue }
                decoded = String(value.dropFirst().dropLast())
            } else {
                guard !value.contains("#"), !value.contains("\\") else { unsupported += 1; continue }
                decoded = value
            }
            entries.append(EnvEntry(line: lineNumber, name: name, value: decoded,
                                    range: NSRange(location: offset + match.range(at: 2).location, length: match.range(at: 2).length)))
        }
        let duplicates = Set(Dictionary(grouping: assignmentNames, by: { $0 }).filter { $0.value.count > 1 }.keys)
        self.entries = entries.filter { !duplicates.contains($0.name) }
        self.unsupportedLines = unsupported + entries.filter { duplicates.contains($0.name) }.count
    }
}
