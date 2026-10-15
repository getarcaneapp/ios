import Testing

@testable import Arcane_Mobile

@Suite
struct ImageReferencePartsTests {
    @Test
    func splitsNamespaceNameAndTag() {
        let parts = ImageReferenceParts("clickhouse/clickhouse-server:24.12-alpine")
        #expect(parts == .init(namespace: "clickhouse/", name: "clickhouse-server", tag: "24.12-alpine"))
    }

    @Test
    func registryPortIsNotATag() {
        let parts = ImageReferenceParts("registry.local:5000/team/api")
        #expect(parts == .init(namespace: "registry.local:5000/team/", name: "api", tag: nil))
    }

    @Test
    func bareNameAndDigestPin() {
        #expect(ImageReferenceParts("nginx:latest") == .init(namespace: "", name: "nginx", tag: "latest"))
        let pinned = ImageReferenceParts("ghcr.io/org/app@sha256:abcdef0123456789")
        #expect(pinned == .init(namespace: "ghcr.io/org/", name: "app", tag: "abcdef012345"))
    }

    @Test
    func untaggedIDHasNoNamespaceOrTag() {
        #expect(ImageReferenceParts("3f2a9c1b7d4e") == .init(namespace: "", name: "3f2a9c1b7d4e", tag: nil))
    }
}
