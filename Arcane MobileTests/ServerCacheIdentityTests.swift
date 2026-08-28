import Foundation
import Testing

@testable import Arcane_Mobile

@Suite
struct ServerCacheIdentityTests {
    @Test
    func canonicalIdentityIncludesEffectivePortAndBasePath() throws {
        let defaultHTTPS = try #require(URL(string: "HTTPS://Example.COM/root"))
        let customHTTPS = try #require(URL(string: "https://example.com:8443/root/"))
        let defaultHTTP = try #require(URL(string: "http://example.com"))

        #expect(ServerCacheIdentity.canonical(for: defaultHTTPS) == "https://example.com:443/root/")
        #expect(ServerCacheIdentity.canonical(for: customHTTPS) == "https://example.com:8443/root/")
        #expect(ServerCacheIdentity.canonical(for: defaultHTTP) == "http://example.com:80/")
    }

    @Test
    func sameHostWithDifferentPortsOrPathsDoesNotCollide() throws {
        let urls = try [
            "https://host:443/",
            "https://host:8443/",
            "https://host:443/arcane/"
        ].map { try #require(URL(string: $0)) }
        let identities = urls.map(ServerCacheIdentity.canonical(for:))

        #expect(Set(identities).count == identities.count)
    }
}
