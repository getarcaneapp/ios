import Foundation
import Arcane

/// Token store that migrates the session from the app's private keychain item
/// to the shared access group (readable by the widget/intents extension)
/// WITHOUT ever risking a sign-out:
///
/// - The legacy private item stays the source of truth: every save writes it
///   first, and only that write can fail the operation. If the shared group
///   is unavailable (entitlement missing, provisioning hiccup), behavior is
///   exactly the pre-migration behavior.
/// - Loads prefer the shared copy, falling back to the legacy item and
///   promoting it opportunistically.
/// - Keeping both in sync means a rollback to an older build still finds a
///   valid (rotated) refresh token in the legacy item.
nonisolated struct MigratingTokenStore: TokenStore {
    private var shared: KeychainTokenStore { SharedKeychain.sharedStore }
    private var legacy: KeychainTokenStore { SharedKeychain.legacyStore }

    func loadTokens() async throws -> TokenPair? {
        if let tokens = try? await shared.loadTokens() {
            return tokens
        }
        // Pre-migration item: try the unqualified query first, then address
        // the app-ID access group explicitly — after the entitlement change
        // some systems stop matching it in unqualified searches.
        var found = try? await legacy.loadTokens()
        if found == nil {
            found = try? await SharedKeychain.legacyAppGroupStore.loadTokens()
        }
        guard let tokens = found else { return nil }
        // One-time promotion; best effort.
        try? await shared.saveTokens(tokens)
        return tokens
    }

    func saveTokens(_ tokens: TokenPair) async throws {
        try await legacy.saveTokens(tokens)
        try? await shared.saveTokens(tokens)
    }

    func clearTokens() async throws {
        try? await shared.clearTokens()
        try await legacy.clearTokens()
    }
}
