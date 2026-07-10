import Foundation
import Arcane
import Security

/// Token store that migrates the session from the app's private keychain item
/// to the shared access group (readable by the widget/intents extension)
/// WITHOUT ever risking a sign-out:
///
/// - The legacy private item stays the source of truth: every save writes it
///   first, and only that write can fail the operation. If the shared group
///   is unavailable (entitlement missing, provisioning hiccup), behavior is
///   exactly the pre-migration behavior.
/// - Loads inspect every copy, select the latest non-expired credential, and
///   heal older copies opportunistically.
/// - Keeping both in sync means a rollback to an older build still finds a
///   valid (rotated) refresh token in the legacy item.
nonisolated struct MigratingTokenStore: TokenStore {
    private let shared: any TokenStore
    private let legacy: any TokenStore
    private let legacyAppGroup: any TokenStore

    init() {
        shared = SharedKeychain.sharedStore
        legacy = SharedKeychain.legacyStore
        legacyAppGroup = SharedKeychain.legacyAppGroupStore
    }

    init(
        shared: any TokenStore,
        legacy: any TokenStore,
        legacyAppGroup: any TokenStore
    ) {
        self.shared = shared
        self.legacy = legacy
        self.legacyAppGroup = legacyAppGroup
    }

    private var allStores: [any TokenStore] {
        [shared, legacy, legacyAppGroup]
    }

    func loadTokens() async throws -> TokenPair? {
        var candidates: [TokenPair] = []
        var successfulReads = 0
        var firstError: Error?

        for store in allStores {
            do {
                let tokens = try await store.loadTokens()
                successfulReads += 1
                if let tokens {
                    candidates.append(tokens)
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        guard successfulReads > 0 else {
            throw firstError ?? KeychainError(status: errSecInteractionNotAllowed)
        }

        let nonExpired = candidates.filter { $0.expiresAt > Date() }
        // Prefer a currently-valid access token. If every access token is
        // expired, keep the newest pair so its refresh token can still rotate.
        guard let selected = (nonExpired.isEmpty ? candidates : nonExpired)
            .max(by: { $0.expiresAt < $1.expiresAt }) else { return nil }

        for store in allStores {
            try? await store.saveTokens(selected)
        }
        return selected
    }

    func saveTokens(_ tokens: TokenPair) async throws {
        try await legacy.saveTokens(tokens)
        try? await shared.saveTokens(tokens)
        try? await legacyAppGroup.saveTokens(tokens)
    }

    func clearTokens() async throws {
        var firstError: Error?
        for store in allStores {
            do {
                try await store.clearTokens()
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }
}
