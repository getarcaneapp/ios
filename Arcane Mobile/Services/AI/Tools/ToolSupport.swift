import Foundation
import Arcane

/// Shared helpers for AI tools. Everything here is `nonisolated` because tool
/// `call()` bodies run off the main actor (project default isolation is
/// MainActor, so the opt-out must be explicit).
enum ToolSupport {
    struct TimeoutError: Error, Sendable {}

    /// Bounds a single API call so a slow endpoint cannot hold the model turn open.
    nonisolated static func withTimeout<T: Sendable>(
        seconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw TimeoutError()
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw TimeoutError() }
            return value
        }
    }

    /// Returns a pluralized noun phrase with a leading count.
    nonisolated static func pluralizedCount(_ count: Int, singular: String, plural: String? = nil) -> String {
        let noun = (count == 1) ? singular : (plural ?? "\(singular)s")
        return "\(count) \(noun)"
    }

    /// Returns a count label that reads naturally for zero values.
    nonisolated static func countSummary(_ count: Int, singular: String, plural: String? = nil) -> String {
        if count == 0 { return "no \(plural ?? "\(singular)s")" }
        return pluralizedCount(count, singular: singular, plural: plural)
    }

    /// Removes whitespace/newlines so model-facing lines stay one line and safe.
    nonisolated static func safeText(_ text: String?, maximumBytes: Int = 160) -> String {
        guard var safe = text?.trimmingCharacters(in: .whitespacesAndNewlines), !safe.isEmpty else {
            return "unknown"
        }
        safe = safe.replacingOccurrences(of: "\n", with: " ")
        safe = safe.replacingOccurrences(of: "\r", with: " ")
        return AITextLimiter.headAndTail(safe, maximumUTF8Bytes: maximumBytes)
    }

    /// Returns a normalized display name with a stable fallback for summaries.
    nonisolated static func displayName(_ text: String?, fallback: String = "unnamed") -> String {
        let name = safeText(text).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return name.isEmpty ? fallback : name
    }

    /// Renders a compact item line using stable labels for model summarization.
    nonisolated static func itemLine(
        name: String,
        status: String? = nil,
        reason: String? = nil,
        image: String? = nil,
        health: String? = nil,
        next: String? = nil,
        internalId: String? = nil
    ) -> String {
        var parts: [String] = [ "name: \(safeText(name))" ]
        if let status, !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("status: \(safeText(status))")
        }
        if let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("reason: \(safeText(reason))")
        }
        if let image, !image.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("image: \(safeText(image))")
        }
        if let health, !health.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("health: \(safeText(health))")
        }
        if let next, !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("next: \(safeText(next))")
        }
        if let internalId, !internalId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("internalId: \(safeText(internalId))")
        }
        return "- " + parts.joined(separator: " | ")
    }

    /// Trims a list to a fixed size and appends a consistent `next` line when needed.
    nonisolated static func truncatedLines<T>(
        _ values: [T],
        limit: Int = 25,
        itemSingular: String,
        itemPlural: String? = nil,
        render: (T) -> String
    ) -> [String] {
        let shown = values.prefix(limit)
        var lines = shown.map(render)
        let remaining = values.count - shown.count
        if remaining > 0 {
            lines.append("next: \(countSummary(remaining, singular: itemSingular, plural: itemPlural)) not shown")
        }
        return lines
    }

    /// Converts SDK errors into model-legible strings instead of raw errors.
    /// v1 servers lack v2-only endpoints (404) — the wording teaches the model
    /// to say "not supported" and move on rather than retry.
    nonisolated static func friendlyFailure(_ error: Error, reading what: String) -> String {
        switch error as? ArcaneError {
        case .notFound:
            return "(\(what) — not supported by this server)"
        case .forbidden, .unauthorized:
            return "(you don't have permission to view \(what))"
        default:
            return "Couldn't read \(what): \(error.localizedDescription)"
        }
    }

    /// True when an env-var key looks like a credential. Over-masking is fine;
    /// leaking a secret into the model transcript is not.
    nonisolated static func isSecretKey(_ key: String) -> Bool {
        let upper = key.uppercased()
        let needles = ["SECRET", "TOKEN", "PASSWORD", "PASSWD", "KEY", "CREDENTIAL", "AUTH"]
        return needles.contains { upper.contains($0) }
    }

    /// Reduces a URL to its host so webhook/registry URLs never leak paths,
    /// query strings, or embedded tokens.
    nonisolated static func maskedHost(_ urlString: String) -> String {
        guard let host = URL(string: urlString)?.host(), !host.isEmpty else { return "(url hidden)" }
        return host
    }
}
