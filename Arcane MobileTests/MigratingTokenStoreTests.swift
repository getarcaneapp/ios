import Arcane
import Foundation
import Testing

@testable import Arcane_Mobile

@Suite
struct MigratingTokenStoreTests {
    @Test
    func boundOriginStoreWinsWithoutConsultingLegacyCopies() async throws {
        let older = TokenPair(
            accessToken: "older",
            refreshToken: "older-refresh",
            expiresAt: Date(timeIntervalSinceNow: 600)
        )
        let newest = TokenPair(
            accessToken: "newest",
            refreshToken: "newest-refresh",
            expiresAt: Date(timeIntervalSinceNow: 1_200)
        )
        let originStore = TestTokenStore(tokens: older)
        let legacy = TestTokenStore(tokens: newest)
        let appGroup = TestTokenStore(tokens: nil)
        let store = MigratingTokenStore(
            origin: "https://arcane.example:443",
            originStore: originStore,
            legacy: legacy,
            legacyAppGroup: appGroup,
            credentialOrigin: { "https://arcane.example:443" }
        )

        let selected = try await store.loadTokens()
        let legacyTokens = try await legacy.loadTokens()
        let appGroupTokens = try await appGroup.loadTokens()
        #expect(selected == older)
        #expect(legacyTokens == newest)
        #expect(appGroupTokens == nil)
    }

    @Test
    func legacyMigrationMovesNewestCredentialIntoBoundOriginStore() async throws {
        let older = TokenPair(
            accessToken: "older",
            refreshToken: "older-refresh",
            expiresAt: Date(timeIntervalSinceNow: 600)
        )
        let newest = TokenPair(
            accessToken: "newest",
            refreshToken: "newest-refresh",
            expiresAt: Date(timeIntervalSinceNow: 1_200)
        )
        let originStore = TestTokenStore(tokens: nil)
        let legacy = TestTokenStore(tokens: older)
        let appGroup = TestTokenStore(tokens: newest)
        let store = MigratingTokenStore(
            origin: "https://arcane.example:443",
            originStore: originStore,
            legacy: legacy,
            legacyAppGroup: appGroup,
            allowsLegacyMigration: true,
            credentialOrigin: { "https://arcane.example:443" }
        )

        let selected = try await store.loadTokens()
        let migrated = try await originStore.loadTokens()
        let legacyTokens = try await legacy.loadTokens()
        let appGroupTokens = try await appGroup.loadTokens()
        #expect(selected == newest)
        #expect(migrated == newest)
        #expect(legacyTokens == nil)
        #expect(appGroupTokens == nil)
    }

    @Test
    func mismatchedOriginCannotLoadCredentials() async throws {
        let tokens = TokenPair(
            accessToken: "token",
            refreshToken: "refresh",
            expiresAt: Date(timeIntervalSinceNow: 600)
        )
        let store = MigratingTokenStore(
            origin: "https://arcane.example:443",
            originStore: TestTokenStore(tokens: tokens),
            legacy: TestTokenStore(tokens: tokens),
            legacyAppGroup: TestTokenStore(tokens: tokens),
            allowsLegacyMigration: true,
            credentialOrigin: { "https://other.example:443" }
        )

        let selected = try await store.loadTokens()
        #expect(selected == nil)
    }

    @Test
    func clearAttemptsEveryStoreAndReportsFailure() async {
        let tokens = TokenPair(
            accessToken: "token",
            refreshToken: "refresh",
            expiresAt: Date(timeIntervalSinceNow: 600)
        )
        let originStore = TestTokenStore(tokens: tokens)
        let legacy = TestTokenStore(tokens: tokens, clearFails: true)
        let appGroup = TestTokenStore(tokens: tokens)
        let store = MigratingTokenStore(
            origin: "https://arcane.example:443",
            originStore: originStore,
            legacy: legacy,
            legacyAppGroup: appGroup,
            credentialOrigin: { "https://arcane.example:443" }
        )

        await #expect(throws: TestTokenStore.TestError.clearFailed) {
            try await store.clearTokens()
        }

        let sharedClears = await originStore.clearCount()
        let legacyClears = await legacy.clearCount()
        let appGroupClears = await appGroup.clearCount()
        #expect(sharedClears == 1)
        #expect(legacyClears == 1)
        #expect(appGroupClears == 1)
    }
}

private actor TestTokenStore: TokenStore {
    enum TestError: Error, Equatable {
        case clearFailed
    }

    private var tokens: TokenPair?
    private let clearFails: Bool
    private var clears = 0

    init(tokens: TokenPair?, clearFails: Bool = false) {
        self.tokens = tokens
        self.clearFails = clearFails
    }

    func loadTokens() async throws -> TokenPair? { tokens }

    func saveTokens(_ tokens: TokenPair) async throws {
        self.tokens = tokens
    }

    func clearTokens() async throws {
        clears += 1
        if clearFails { throw TestError.clearFailed }
        tokens = nil
    }

    func clearCount() -> Int { clears }
}
