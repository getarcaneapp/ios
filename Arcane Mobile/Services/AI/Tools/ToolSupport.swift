import Foundation
import Arcane

/// Shared helpers for AI tools. Everything here is `nonisolated` because tool
/// `call()` bodies run off the main actor (project default isolation is
/// MainActor, so the opt-out must be explicit).
enum ToolSupport {
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
