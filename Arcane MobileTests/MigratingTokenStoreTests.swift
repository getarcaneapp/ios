import Arcane
import Foundation
import XCTest

@testable import Arcane_Mobile

final class MigratingTokenStoreTests: XCTestCase {
    func testLoadChoosesNewestCredentialAndHealsEveryStore() async throws {
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
        let shared = TestTokenStore(tokens: older)
        let legacy = TestTokenStore(tokens: newest)
        let appGroup = TestTokenStore(tokens: nil)
        let store = MigratingTokenStore(
            shared: shared,
            legacy: legacy,
            legacyAppGroup: appGroup
        )

        let selected = try await store.loadTokens()
        let healedShared = try await shared.loadTokens()
        let healedLegacy = try await legacy.loadTokens()
        let healedAppGroup = try await appGroup.loadTokens()
        XCTAssertEqual(selected, newest)
        XCTAssertEqual(healedShared, newest)
        XCTAssertEqual(healedLegacy, newest)
        XCTAssertEqual(healedAppGroup, newest)
    }

    func testClearAttemptsEveryStoreAndReportsFailure() async throws {
        let tokens = TokenPair(
            accessToken: "token",
            refreshToken: "refresh",
            expiresAt: Date(timeIntervalSinceNow: 600)
        )
        let shared = TestTokenStore(tokens: tokens)
        let legacy = TestTokenStore(tokens: tokens, clearFails: true)
        let appGroup = TestTokenStore(tokens: tokens)
        let store = MigratingTokenStore(
            shared: shared,
            legacy: legacy,
            legacyAppGroup: appGroup
        )

        do {
            try await store.clearTokens()
            XCTFail("Expected clear failure")
        } catch TestTokenStore.TestError.clearFailed {}

        let sharedClears = await shared.clearCount()
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
