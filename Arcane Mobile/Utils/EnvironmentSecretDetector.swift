import Foundation

nonisolated struct ParsedEnvironmentVariable: Equatable {
    let rawValue: String
    let name: String
    let value: String?
    let isPotentialSecret: Bool

    init(rawValue: String) {
        self.rawValue = rawValue

        guard let separator = rawValue.firstIndex(of: "=") else {
            name = rawValue
            value = nil
            isPotentialSecret = false
            return
        }

        let parsedName = String(rawValue[..<separator])
        let parsedValue = String(rawValue[rawValue.index(after: separator)...])
        name = parsedName
        value = parsedValue
        isPotentialSecret = EnvironmentSecretDetector.isPotentialSecret(
            name: parsedName,
            value: parsedValue
        )
    }
}

nonisolated enum EnvironmentSecretDetector {
    private static let metadataSuffixes: Set<String> = [
        "ALGORITHM", "ARN", "DISABLED", "ENABLED", "ENDPOINT", "EXPIRATION",
        "EXPIRES", "EXPIRY", "FILE", "FORMAT", "HOST", "ID", "LENGTH",
        "METHOD", "MODE", "NAME", "PATH", "PORT", "PROVIDER", "REQUIRED",
        "TTL", "TYPE", "URI", "URL", "VERSION",
    ]

    private static let strongSecretWords: Set<String> = [
        "AUTH", "AUTHORIZATION", "CREDENTIAL", "CREDENTIALS", "PASSCODE",
        "PASSPHRASE", "PASSWD", "PASSWORD", "SECRET", "SIG", "SIGNATURE",
        "TOKEN",
    ]

    private static let keyQualifiers: Set<String> = [
        "ACCESS", "API", "APP", "APPLICATION", "AUTH", "ENCRYPTION", "MASTER",
        "PRIVATE", "SECRET", "SIGNING", "SSH",
    ]

    private static let compactSecretNames: Set<String> = [
        "APIKEY", "APPKEY", "AUTHTOKEN", "CLIENTSECRET", "PRIVATEKEY",
        "REFRESHTOKEN",
    ]

    private static let secretValuePrefixes = [
        "aiza", "bearer ", "basic ", "gho_", "ghp_", "ghr_", "ghs_", "ghu_",
        "github_pat_", "glpat-", "npm_", "pypi-", "rk_live_", "rk_test_",
        "sk_live_", "sk_test_", "xox",
    ]

    static func isPotentialSecret(name: String, value: String) -> Bool {
        let candidate = removingMatchingQuotes(
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !candidate.isEmpty else { return false }

        return nameLooksSensitive(name)
            || valueLooksSensitive(candidate)
    }

    private static func nameLooksSensitive(_ name: String) -> Bool {
        let words = name
            .uppercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        guard let suffix = words.last else { return false }

        let compactName = words.joined()
        if compactSecretNames.contains(compactName) {
            return true
        }

        if words.contains("WEBHOOK"), suffix == "URL" || suffix == "URI" {
            return true
        }

        if metadataSuffixes.contains(suffix) {
            return false
        }

        if words.contains(where: strongSecretWords.contains) {
            return true
        }

        guard suffix == "KEY" else { return false }
        if words.contains("PUBLIC"), !words.contains("PRIVATE") {
            return false
        }
        return words.count == 1 || words.contains(where: keyQualifiers.contains)
    }

    private static func valueLooksSensitive(_ value: String) -> Bool {
        let lowercaseValue = value.lowercased()
        if secretValuePrefixes.contains(where: lowercaseValue.hasPrefix) {
            return true
        }

        let uppercaseValue = value.uppercased()
        if uppercaseValue.contains("-----BEGIN "),
           uppercaseValue.contains("PRIVATE KEY-----") {
            return true
        }

        return looksLikeJSONWebToken(value)
            || containsURLCredential(value)
            || containsCredentialAssignment(value)
    }

    private static func looksLikeJSONWebToken(_ value: String) -> Bool {
        let segments = value.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              value.count >= 40,
              segments[0].hasPrefix("eyJ") else {
            return false
        }

        return segments.allSatisfy { segment in
            !segment.isEmpty && segment.utf8.allSatisfy { byte in
                switch byte {
                case 45, 48...57, 65...90, 95, 97...122:
                    true
                default:
                    false
                }
            }
        }
    }

    private static func containsURLCredential(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme != nil else {
            return false
        }

        if components.password?.isEmpty == false {
            return true
        }

        return components.queryItems?.contains { item in
            guard let itemValue = item.value, !itemValue.isEmpty else { return false }
            return nameLooksSensitive(item.name)
        } == true
    }

    private static func containsCredentialAssignment(_ value: String) -> Bool {
        value.split(
            omittingEmptySubsequences: true,
            whereSeparator: { $0 == ";" || $0 == "&" || $0 == "," || $0.isNewline }
        ).contains { field in
            let fieldText = String(field)
            guard let separator = fieldText.firstIndex(of: "=") else { return false }
            let fieldName = String(fieldText[..<separator])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fieldValue = String(fieldText[fieldText.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return !fieldValue.isEmpty && nameLooksSensitive(fieldName)
        }
    }

    private static func removingMatchingQuotes(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first,
              let last = value.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }
}
