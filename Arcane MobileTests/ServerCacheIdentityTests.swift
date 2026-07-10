import Foundation
import XCTest

@testable import Arcane_Mobile

final class ServerCacheIdentityTests: XCTestCase {
    func testCanonicalIdentityIncludesEffectivePortAndBasePath() throws {
        XCTAssertEqual(
            ServerCacheIdentity.canonical(for: try XCTUnwrap(URL(string: "HTTPS://Example.COM/root"))),
            "https://example.com:443/root/"
        )
        XCTAssertEqual(
            ServerCacheIdentity.canonical(for: try XCTUnwrap(URL(string: "https://example.com:8443/root/"))),
            "https://example.com:8443/root/"
        )
        XCTAssertEqual(
            ServerCacheIdentity.canonical(for: try XCTUnwrap(URL(string: "http://example.com"))),
            "http://example.com:80/"
        )
    }

    func testSameHostWithDifferentPortsOrPathsDoesNotCollide() throws {
        let identities = [
            "https://host:443/",
            "https://host:8443/",
            "https://host:443/arcane/"
        ].map { ServerCacheIdentity.canonical(for: URL(string: $0)!) }
        XCTAssertEqual(Set(identities).count, identities.count)
    }
}
