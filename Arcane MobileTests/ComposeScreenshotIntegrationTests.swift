import Testing
@testable import Arcane_Mobile

/// Mirrors the shapes in the reported Arcane service with synthetic deployment values.
enum ComposeScreenshotFixture {
    static let source = """
    services:
      arcane:
        image: "getarcaneapp/manager:next"
        # image: example.test/arcane:next
        pull_policy: always
        container_name: arcane
        domainname: svc.example.test
        hostname: arcane.svc.example.test
        volumes:
          - "/var/run/docker.sock:/var/run/docker.sock"
          - "arcane-data:/app/data"
          - "arcane-backups:/backups"
          - "/opt/arcane:/opt/arcane"
        restart: unless-stopped
        env_file: .env
        networks:
          vlan25:
            ipv4_address: 192.0.2.40
        healthcheck:
          test: ["CMD", "/app/arcane", "health"]
          interval: 30s
          timeout: 5s
          retries: 3
        extra_hosts:
          - "id.example.test:192.0.2.43"
        dns:
          - 192.0.2.5
          - 192.0.2.53
        dns_opt:
          - trust-ad
          - edns0
        dns_search:
          - example.test
          - lxc.example.test
          - svc.example.test
        labels:
          - "traefik.enable=true"
          - "traefik.docker.allownonrunning=true"
    volumes:
      arcane-data:
        external: true
      arcane-backups:
        external: true
    networks:
      vlan25:
        external: true
    """
}

@Suite("Arcane service configuration")
struct ComposeScreenshotIntegrationTests {
    @Test func allScreenshotScalarFieldsAreEditable() throws {
        let doc = try ComposeDocument(ComposeScreenshotFixture.source)
        for key in ["image", "pull_policy", "container_name", "domainname", "hostname", "restart", "env_file"] {
            #expect(doc.scalar(at: ["services", "arcane", key]) != nil)
            #expect(doc.isEditable(at: ["services", "arcane", key]))
        }
    }

    @Test func staticAddressEditPreservesHealthcheckAndComments() throws {
        let original = ComposeScreenshotFixture.source
        let edited = try ComposeDocument(original).setting(ComposeDocument.quoted("192.0.2.41"), at: ["services", "arcane", "networks", "vlan25", "ipv4_address"])
        #expect(edited == original.replacingOccurrences(of: "ipv4_address: 192.0.2.40", with: "ipv4_address: \"192.0.2.41\""))
    }

    @Test func healthCommandEditPreservesInlineArrayAndRestOfFile() throws {
        let original = ComposeScreenshotFixture.source
        let path = ["services", "arcane", "healthcheck", "test"]
        let doc = try ComposeDocument(original)
        #expect(doc.items(at: path)?.count == 3)
        #expect(doc.isEditable(at: ["services", "arcane", "healthcheck"]))
        let edited = try doc.settingItem(ComposeDocument.quoted("status"), at: path, index: 2)
        #expect(edited == original.replacingOccurrences(of: "\"health\"]", with: "\"status\"]"))
    }

    @Test func durationEditPreservesCommandAndIntegerRetries() throws {
        let original = ComposeScreenshotFixture.source
        let edited = try ComposeDocument(original).setting(ComposeDocument.quoted("45s"), at: ["services", "arcane", "healthcheck", "interval"])
        #expect(edited == original.replacingOccurrences(of: "interval: 30s", with: "interval: \"45s\""))
        #expect(try ComposeDocument(edited).rawValue(at: ["services", "arcane", "healthcheck", "retries"]) == "3")
    }

    @Test func nativeListsAreAvailableWithoutNormalizingSource() throws {
        let doc = try ComposeDocument(ComposeScreenshotFixture.source)
        for key in ["volumes", "extra_hosts", "dns", "dns_opt", "dns_search", "labels"] {
            #expect(doc.items(at: ["services", "arcane", key])?.isEmpty == false)
            #expect(doc.isEditable(at: ["services", "arcane", key]))
        }
        #expect(doc.source == ComposeScreenshotFixture.source)
    }
}
