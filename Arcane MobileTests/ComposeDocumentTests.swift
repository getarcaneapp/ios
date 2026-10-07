import Testing
@testable import Arcane_Mobile

@Suite
struct ComposeDocumentTests {
    @Test func noOpPreservesEveryByte() throws {
        let source = "# header\r\nservices:\r\n  web:\r\n    image: 'nginx:latest' # keep\r\nx-extra: ${VALUE}\r\n"
        let document = try ComposeDocument(source)
        #expect(document.source == source)
        #expect(try document.setting(ComposeDocument.quoted("nginx:latest"), at: ["services", "web", "image"]) == source)
    }

    @Test func scalarEditPreservesUnicodeCommentsAndExtensions() throws {
        let source = "# 🐳\nservices:\n  web:\n    image: nginx # pin\n    labels:\n      title: café\nx-extra: ${KEEP}\n"
        let changed = try ComposeDocument(source).setting("alpine", at: ["services", "web", "image"])
        #expect(changed == source.replacingOccurrences(of: "image: nginx", with: "image: alpine"))
        #expect(try ComposeDocument(changed).scalar(at: ["services", "web", "labels", "title"]) == "café")
    }

    @Test func sequenceEditPreservesOtherRowsAndComments() throws {
        let source = "services:\n  web:\n    ports:\n      - '80:80' # first\n      - '443:443' # secure\n"
        let document = try ComposeDocument(source)
        #expect(document.items(at: ["services", "web", "ports"]) == ["'80:80'", "'443:443'"])
        #expect(try document.settingItem("'8080:80'", at: ["services", "web", "ports"], index: 0) == source.replacingOccurrences(of: "'80:80'", with: "'8080:80'"))
    }

    @Test func malformedAndDuplicateKeysAreRejected() {
        #expect(throws: (any Error).self) { try ComposeDocument("services: [broken") }
        #expect(throws: (any Error).self) { try ComposeDocument("services:\n  web: {}\n  web: {}\n") }
    }

    @Test func anchorsAndMergesRemainUntouched() throws {
        let source = "x-base: &base\n  image: nginx\nservices:\n  web:\n    <<: *base\n  other:\n    image: alpine\n"
        let document = try ComposeDocument(source)
        #expect(!document.isEditable(at: ["services", "web", "image"]))
        #expect(throws: (any Error).self) { try document.setting("busybox", at: ["services", "web", "image"]) }
        let changed = try document.setting("busybox", at: ["services", "other", "image"])
        #expect(changed == source.replacingOccurrences(of: "image: alpine", with: "image: busybox"))
    }

    @Test func additionsAndRemovalRetainCRLF() throws {
        let source = "services:\r\n  web:\r\n    image: nginx\r\n    restart: always\r\nx-keep: true\r\n"
        let added = try ComposeDocument(source).setting("'80:80'", at: ["services", "web", "command"])
        #expect(added.contains("    \"command\": '80:80'\r\n"))
        #expect(!added.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        let removed = try ComposeDocument(source).removing(at: ["services", "web", "restart"])
        #expect(removed == source.replacingOccurrences(of: "    restart: always\r\n", with: ""))
    }

    @Test func addsServiceAndNestedFields() throws {
        let document = try ComposeDocument("services:\n  web:\n    image: nginx\n")
        let added = try document.setting("image: postgres", at: ["services", "db"])
        #expect(try ComposeDocument(added).services == ["web", "db"])
        #expect(try ComposeDocument(added).scalar(at: ["services", "db", "image"]) == "postgres")
    }

    @Test(arguments: ["services: {}\n", "services:\n", ""])
    func fillsEmptyMappings(source: String) throws {
        let changed = try ComposeDocument(source).setting("image: nginx", at: ["services", "web"])
        #expect(try ComposeDocument(changed).scalar(at: ["services", "web", "image"]) == "nginx")
    }

    @Test func sequenceAppendRemoveAndEmptyReuse() throws {
        let path = ["services", "web", "ports"]
        let source = "services:\n  web:\n    image: nginx\n    ports:\n      - '80:80' # keep\n"
        let appended = try ComposeDocument(source).appendingItem("'443:443'", at: path)
        #expect(appended.contains("- '80:80' # keep\n"))
        #expect(try ComposeDocument(appended).items(at: path)?.count == 2)
        let removed = try ComposeDocument(appended).removingItem(at: path, index: 1)
        #expect(try ComposeDocument(removed).items(at: path)?.count == 1)
        let empty = try ComposeDocument(removed).removingItem(at: path, index: 0)
        #expect(try ComposeDocument(empty).isEditable(at: path))
        #expect(try ComposeDocument(empty).items(at: path) == [])
        let refilled = try ComposeDocument(empty).appendingItem("'8080:80'", at: path)
        #expect(try ComposeDocument(refilled).items(at: path) == ["'8080:80'"])
    }

    @Test func unsupportedStructuresFailClosed() throws {
        for source in ["services:\n  web: {image: nginx}\n", "services:\n  web: &web\n    image: nginx\n", "services:\n  web: !custom\n    image: nginx\n"] {
            let document = try ComposeDocument(source)
            #expect(throws: (any Error).self) { try document.setting("alpine", at: ["services", "web", "image"]) }
        }
    }

    @Test func removingLastServiceAllowsAddingAnother() throws {
        let source = "services:\n  web:\n    image: nginx\nx-extra: true\n"
        let removed = try ComposeDocument(source).removing(at: ["services", "web"])
        let added = try ComposeDocument(removed).setting("image: alpine", at: ["services", "other"])
        #expect(try ComposeDocument(added).services == ["other"])
        #expect(added.contains("x-extra: true"))
    }
    @Test func healthcheckFlowSequencePreservesScreenshotFields() throws {
        let source = """
        # deployment
        services:
          arcane:
            image: ghcr.io/getarcaneapp/arcane:latest
            container_name: arcane
            restart: unless-stopped
            ports:
              - "3552:3552"
            volumes:
              - /var/run/docker.sock:/var/run/docker.sock
              - arcane-data:/app/data
            environment:
              APP_URL: https://arcane.example.test
              ENCRYPTION_KEY: ${ENCRYPTION_KEY}
              JWT_SECRET: ${JWT_SECRET}
            healthcheck:
              test: ["CMD", "/app/arcane", "health"] # keep
              interval: 30s
              timeout: 10s
              retries: 3
              start_period: 10s
        volumes:
          arcane-data:
        """
        let path = ["services", "arcane", "healthcheck", "test"]
        let document = try ComposeDocument(source)
        #expect(document.isEditable(at: ["services", "arcane"]))
        #expect(document.items(at: path) == ["\"CMD\"", "\"/app/arcane\"", "\"health\""])
        #expect(try document.settingItem("\"status\"", at: path, index: 2) == source.replacingOccurrences(of: "\"health\"", with: "\"status\""))
        #expect(try document.appendingItem("\"--verbose\"", at: path) == source.replacingOccurrences(of: "\"health\"]", with: "\"health\", \"--verbose\"]"))
        #expect(try ComposeDocument(document.removingItem(at: path, index: 1)).items(at: path) == ["\"CMD\"", "\"health\""])
    }

    @Test func flowSequenceCommentsDelimitersAndCRLFArePreserved() throws {
        let source = "test: [\"CMD\", # mode\r\n  'health', # command\r\n] # end\r\nx-keep: café\r\n"
        let path = ["test"]
        let document = try ComposeDocument(source)
        let removed = try document.removingItem(at: path, index: 0)
        #expect(removed == source.replacingOccurrences(of: "\"CMD\",", with: ""))
        let appended = try document.appendingItem("'status'", at: path)
        #expect(appended == source.replacingOccurrences(of: "] # end", with: " 'status'] # end"))
        #expect(try ComposeDocument(appended).items(at: path) == ["\"CMD\"", "'health'", "'status'"])
        let empty = try ComposeDocument("test: [ 'health', ] # keep\n").removingItem(at: path, index: 0)
        #expect(empty == "test: [  ] # keep\n")
        #expect(try ComposeDocument(empty).appendingItem("'status'", at: path) == "test: [  'status'] # keep\n")
    }

    @Test func unsafeFlowSequencesFailClosed() throws {
        for value in ["[&command CMD, health]", "[!custom CMD, health]", "[*command]", "[{command: health}]", "[[CMD, health]]", "[command: health]"] {
            let document = try ComposeDocument("test: " + value + "\n")
            #expect(!document.isEditable(at: ["test"]))
            #expect(throws: (any Error).self) { try document.settingItem("'status'", at: ["test"], index: 0) }
            #expect(throws: (any Error).self) { try document.removingItem(at: ["test"], index: 0) }
            #expect(throws: (any Error).self) { try document.appendingItem("'status'", at: ["test"]) }
        }
        let document = try ComposeDocument("test: [CMD, health]\n")
        for value in ["one, two", "*command", "&command CMD", "!custom CMD", "{command: health}"] {
            #expect(throws: (any Error).self) { try document.appendingItem(value, at: ["test"]) }
        }
    }

    @Test(arguments: ["{}", ""])
    func addsNetworkAddressToEmptyAttachment(value: String) throws {
        let source = "services:\r\n  arcane:\r\n    networks:\r\n      vlan25: " + value + " # keep attachment\r\n    image: arcane\r\nx-keep: true\r\n"
        let path = ["services", "arcane", "networks", "vlan25", "ipv4_address"]
        let document = try ComposeDocument(source)
        #expect(document.isEditable(at: path))
        let changed = try document.setting("'192.0.2.25'", at: path)
        #expect(try ComposeDocument(changed).scalar(at: path) == "192.0.2.25")
        #expect(changed == source.replacingOccurrences(of: "vlan25: " + value + " # keep attachment\r\n", with: "vlan25:  # keep attachment\r\n        \"ipv4_address\": '192.0.2.25'\r\n"))
    }

    @Test(arguments: ["{aliases: [arcane]}", "arcane", "[]", "&network {}", "!custom {}"])
    func refusesAddressUnderUnsupportedAttachment(value: String) throws {
        let source = "services:\n  arcane:\n    networks:\n      vlan25: " + value + "\n"
        let path = ["services", "arcane", "networks", "vlan25", "ipv4_address"]
        let document = try ComposeDocument(source)
        #expect(!document.isEditable(at: path))
        #expect(throws: (any Error).self) { try document.setting("'192.0.2.25'", at: path) }
    }

}
