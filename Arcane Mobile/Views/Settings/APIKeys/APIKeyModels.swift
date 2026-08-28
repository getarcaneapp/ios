import Foundation
import Arcane

/// API-key fields added by Arcane v2 that are not yet surfaced by the SDK's
/// `APIKey` model. Keeping this additive and optional lets the detail screen
/// decode both v1 and v2 responses without changing libarcane-swift.
nonisolated struct APIKeyServerMetadata: Decodable, Sendable {
    let kind: String?
    let isBootstrap: Bool?
    let permissions: [ApiKeyPermissionGrant]?
}

/// Shared create/update payload. `permissions` is omitted for v1 and personal
/// keys, while v2 scoped keys send the same global grants as Arcane's web UI.
nonisolated struct APIKeyMutationRequest: Encodable, Sendable {
    let name: String
    let description: String?
    let expiresAt: Date?
    let permissions: [ApiKeyPermissionGrant]?
}

/// One-time secret presentation used after creating or rotating a key.
struct APIKeySecretPresentation: Identifiable {
    let id = UUID()
    let key: String
    let navigationTitle: String
    let heading: String
    let message: String
    let warning: String?

    static func created(_ key: String) -> APIKeySecretPresentation {
        APIKeySecretPresentation(
            key: key,
            navigationTitle: "API Key Created",
            heading: "Save Your API Key",
            message: "This key will only be shown once. Make sure to save it somewhere safe.",
            warning: nil
        )
    }

    static func rotated(_ key: String, oldKeyRevoked: Bool) -> APIKeySecretPresentation {
        APIKeySecretPresentation(
            key: key,
            navigationTitle: "API Key Rotated",
            heading: "Save Your Rotated Key",
            message: "This replacement key will only be shown once. Update anything that used the old key.",
            warning: oldKeyRevoked
                ? nil
                : "The replacement was created, but the old key could not be revoked. Both keys may still be active."
        )
    }
}
