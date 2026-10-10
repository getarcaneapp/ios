import Foundation

nonisolated extension EnvDocument {
    static func hasClosingQuote(in text: Substring, quote: Character) -> Bool {
        var escaped = false
        for character in text {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == quote { return true }
        }
        return false
    }

    func setting(_ value: String, entry: EnvEntry) throws -> String {
        guard
            entries.contains(where: {
                $0.line == entry.line && $0.name == entry.name && $0.range == entry.range && $0.value == entry.value
            })
        else { throw ComposeFormError.changed }
        if value == entry.value { return source }
        guard !value.contains("\n"), !value.contains("\r") else {
            throw ComposeFormError.invalid("Edit multiline values in the text editor.")
        }
        let old = (source as NSString).substring(with: entry.range)
        let encoded: String
        if old.hasPrefix("'") {
            guard !value.contains("'") else { throw ComposeFormError.invalid("Edit quoted values in the text editor.") }
            encoded = "'" + value + "'"
        } else if old.hasPrefix("\"") {
            guard !value.contains("\""), !value.contains("\\") else {
                throw ComposeFormError.invalid("Edit escaped values in the text editor.")
            }
            encoded = "\"" + value + "\""
        } else {
            guard !value.contains("#"), !value.contains("\\"), !value.contains("'"), !value.contains("\""),
                value == value.trimmingCharacters(in: .whitespaces)
            else { throw ComposeFormError.invalid("Edit quoted or escaped values in the text editor.") }
            encoded = value
        }
        return (source as NSString).replacingCharacters(in: entry.range, with: encoded)
    }

    func adding(_ name: String) throws -> String {
        guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
            throw ComposeFormError.invalid("Enter a valid variable name.")
        }
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard source.range(of: "(?m)^\\s*(?:export\\s+)?" + escaped + "\\s*=", options: .regularExpression) == nil
        else { throw ComposeFormError.duplicate }
        let ending = source.contains("\r\n") ? "\r\n" : "\n"
        return source + (source.isEmpty || source.hasSuffix("\n") || source.hasSuffix("\r\n") ? "" : ending) + name
            + "=" + ending
    }

    func removing(_ entry: EnvEntry) -> String {
        guard
            entries.contains(where: {
                $0.line == entry.line && $0.name == entry.name && $0.range == entry.range && $0.value == entry.value
            })
        else { return source }
        let ns = source as NSString
        return ns.replacingCharacters(in: ns.lineRange(for: entry.range), with: "")
    }
}
