import Foundation
import Arcane
import Security

/// Origin-bound token store shared with widgets and App Intents. Legacy items
/// are consulted only during the one-time upgrade migration, then removed so
/// credentials can never follow a user to a differently configured server.
nonisolated struct MigratingTokenStore: TokenStore {
    private let lease: CredentialLease
    private let persistence: CredentialPersistenceCoordinator
    private let origin: String
    private let originStore: any TokenStore
    private let legacy: any TokenStore
    private let legacyAppGroup: any TokenStore
    private let allowsLegacyMigration: Bool
    private let credentialOrigin: @Sendable () -> String?

    init(origin: String, allowsLegacyMigration: Bool = false, lease: CredentialLease = CredentialLease(), persistence: CredentialPersistenceCoordinator = CredentialPersistenceCoordinator()) {
        self.lease = lease
        self.persistence = persistence
        self.origin = origin
        originStore = SharedKeychain.sharedStore(for: origin, validating: { lease.isActive || lease.canClear })
        legacy = SharedKeychain.legacyStore
        legacyAppGroup = SharedKeychain.legacyAppGroupStore
        self.allowsLegacyMigration = allowsLegacyMigration
        credentialOrigin = { SharedKeychain.credentialOrigin }
    }

    init(
        origin: String,
        originStore: any TokenStore,
        legacy: any TokenStore,
        legacyAppGroup: any TokenStore,
        allowsLegacyMigration: Bool = false,
        lease: CredentialLease = CredentialLease(),
        persistence: CredentialPersistenceCoordinator = CredentialPersistenceCoordinator(),
        credentialOrigin: @escaping @Sendable () -> String? = { SharedKeychain.credentialOrigin }
    ) {
        self.lease = lease
        self.persistence = persistence
        self.origin = origin
        self.originStore = originStore
        self.legacy = legacy
        self.legacyAppGroup = legacyAppGroup
        self.allowsLegacyMigration = allowsLegacyMigration
        self.credentialOrigin = credentialOrigin
    }

    func loadTokens() async throws -> TokenPair? {
        guard (lease.isActive || lease.canClear), credentialOrigin() == origin else { return nil }
        if let tokens = try await originStore.loadTokens() {
            guard lease.isActive || lease.canClear else { throw CancellationError() }
            return tokens
        }
        guard allowsLegacyMigration else { return nil }

        var candidates: [TokenPair] = []
        var successfulReads = 0
        var firstError: Error?

        for store in [legacy, legacyAppGroup] {
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

        try await persistence.save(selected, to: originStore, lease: lease, bind: {})
        try? await legacy.clearTokens()
        try? await legacyAppGroup.clearTokens()
        return selected
    }

    func saveTokens(_ tokens: TokenPair) async throws {
        try await persistence.save(tokens, to: originStore, lease: lease) { [origin] in
            SharedKeychain.bindCredentials(to: origin)
        }
    }

    func clearTokens() async throws {
        try await persistence.clear(stores: [originStore, legacy, legacyAppGroup], lease: lease) { [origin] in
            SharedKeychain.unbindCredentials(matching: origin)
        }
    }
}
