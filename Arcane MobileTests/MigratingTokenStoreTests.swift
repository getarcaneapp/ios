import Arcane
import Foundation
import XCTest

@testable import Arcane_Mobile

final class MigratingTokenStoreTests: XCTestCase {
    func testBoundOriginStoreWinsWithoutConsultingLegacyCopies() async throws {
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
        XCTAssertEqual(selected, older)
        XCTAssertEqual(legacyTokens, newest)
        XCTAssertNil(appGroupTokens)
    }

    func testLegacyMigrationMovesNewestCredentialIntoBoundOriginStore() async throws {
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
        XCTAssertEqual(selected, newest)
        XCTAssertEqual(migrated, newest)
        XCTAssertNil(legacyTokens)
        XCTAssertNil(appGroupTokens)
    }

    func testMismatchedOriginCannotLoadCredentials() async throws {
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
        XCTAssertNil(selected)
    }

    func testClearAttemptsEveryStoreAndReportsFailure() async throws {
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

        do {
            try await store.clearTokens()
            XCTFail("Expected clear failure")
        } catch TestTokenStore.TestError.clearFailed {}

        let sharedClears = await originStore.clearCount()
        let legacyClears = await legacy.clearCount()
        let appGroupClears = await appGroup.clearCount()
        XCTAssertEqual(sharedClears, 1)
        XCTAssertEqual(legacyClears, 1)
        XCTAssertEqual(appGroupClears, 1)
    }
}

private actor TestTokenStore: TokenStore {
    enum TestError: Error {
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
