import Testing
@testable import Arcane_Mobile

@Suite struct ComposeNativeFieldsTests {
    @Test func draftSavesConfiguredDictionaryAndSkipsBlankEntries() throws {
        let parent: [ComposeFieldPathComponent] = [.key("services"), .key("web")]
        var draft = ComposeSettingDraft(name: "annotations", schemaPath: parent + [.key("annotations")], included: true)
        draft.kind = .mapping
        draft.prepareFields()
        draft.children[0].name = "owner"
        draft.children[0].value = "team"
        draft.appendEntry()
        let source = "# keep\nservices: {web: {image: nginx}}\n"
        let result = try draft.adding(to: source, at: parent)
        let document = try ComposeDocument(result)
        #expect(document.nativeField(at: parent + [.key("annotations"), .key("owner")]).value == "team")
        #expect(document.nativeFields(at: parent + [.key("annotations")]).count == 1)
        #expect(result.contains("# keep"))
        draft.children[1].name = "owner"
        draft.children[1].value = "duplicate"
        #expect(throws: (any Error).self) { try draft.adding(to: source, at: parent) }
        #expect(try ComposeDocument(source).nativeFields(at: parent).count == 1)
    }

    @Test func draftCreatesServiceWithConfiguredListAndDefaultBoolean() throws {
        var draft = ComposeSettingDraft(name: "cap_add", schemaPath: [.key("services"), .key("web"), .key("cap_add")], included: true)
        draft.prepareFields()
        draft.children[0].value = "NET_ADMIN"
        let result = try draft.adding(to: "# keep\nservices: {}\n", at: [], newService: "web")
        let path: [ComposeFieldPathComponent] = [.key("services"), .key("web")]
        #expect(try ComposeDocument(result).nativeField(at: path + [.key("cap_add"), .index(0)]).value == "NET_ADMIN")
        var toggle = ComposeSettingDraft(name: "privileged", schemaPath: path + [.key("privileged")], included: true)
        toggle.kind = .boolean
        let updated = try toggle.adding(to: result, at: path)
        #expect(try ComposeDocument(updated).nativeField(at: path + [.key("privileged")]).value == "false")
    }

    @Test func createsServiceWithItsFirstSettingAndPreservesProjectFields() throws {
        for source in ["# keep\nnetworks:\n  shared: {}\n", "# keep\nservices: {existing: {image: alpine}}\nnetworks: {shared: {}}\n"] {
            let result = try ComposeDocument(source).addingService("worker", field: "image", value: "busybox:latest", kind: .string)
            let document = try ComposeDocument(result)
            #expect(document.services.contains("worker"))
            #expect(document.nativeField(at: [.key("services"), .key("worker"), .key("image")]).value == "busybox:latest")
            #expect(document.nativeField(at: [.key("networks"), .key("shared")]).kind == .mapping)
            #expect(result.contains("# keep"))
            if source.contains("existing") { #expect(document.services.contains("existing")) }
        }
    }

    @Test func rejectsDuplicateOrInvalidServiceWithoutChangingSource() throws {
        let source = "services:\n  web:\n    image: nginx\n"
        let document = try ComposeDocument(source)
        for name in ["web", "", "bad name", "bad\nname"] {
            #expect(throws: (any Error).self) {
                try document.addingService(name, field: "image", value: "alpine", kind: .string)
            }
        }
        #expect(throws: (any Error).self) {
            try document.addingService("worker", field: "scale", value: "not a number", kind: .number)
        }
        #expect(document.source == source)
    }

    @Test func nestedBlockFieldsPreserveUnrelatedSource() throws {
        let source = "# header\r\nservices:\r\n  web:\r\n    healthcheck:\r\n      retries: 3 # attempts\r\n      test:\r\n        - CMD\r\n        - curl\r\nx-extra: ${KEEP}\r\n"
        let path: [ComposeFieldPathComponent] = [.key("services"), .key("web"), .key("healthcheck"), .key("retries")]
        let changed = try ComposeDocument(source).settingNative("5", kind: .number, at: path)
        #expect(changed == source.replacingOccurrences(of: "retries: 3", with: "retries: 5"))
        let item = Array(path.dropLast()) + [.key("test"), .index(1)]
        let updated = try ComposeDocument(changed).settingNative("wget", kind: .string, at: item)
        #expect(updated.contains("- \"wget\""))
        #expect(updated.contains("x-extra: ${KEEP}\r\n"))
    }
    @Test func nestedFlowFieldsAreEditedInPlace() throws {
        let source = "settings: {enabled: true, values: [1, {name: 'old', keep: yes}]} # keep\n"
        let path: [ComposeFieldPathComponent] = [.key("settings"), .key("values"), .index(1), .key("name")]
        let changed = try ComposeDocument(source).settingNative("new", kind: .string, at: path)
        #expect(changed == source.replacingOccurrences(of: "'old'", with: "\"new\""))
        let added = try ComposeDocument(changed).addingNative("false", kind: .boolean, key: "other", at: [.key("settings")])
        #expect(try ComposeDocument(added).nativeField(at: [.key("settings"), .key("other")]).kind == .boolean)
        let removed = try ComposeDocument(added).removingNative(at: [.key("settings"), .key("enabled")])
        #expect(removed.contains("# keep"))
        #expect(!removed.contains("enabled"))
    }
    @Test func nullAndMissingObjectsCanBeFilled() throws {
        for source in ["settings: null # keep\n", "settings: # keep\n", "# keep\n"] {
            let updated = try ComposeDocument(source).addingNative("value", kind: .string, key: "name", at: [.key("settings")])
            #expect(try ComposeDocument(updated).nativeField(at: [.key("settings"), .key("name")]).value == "value")
            #expect(updated.contains("# keep"))
        }
    }
    @Test func nativeTypeChangesDoNotConfuseStringsAndBooleans() throws {
        let source = "enabled: true\ncount: '12'\n"
        let text = try ComposeDocument(source).settingNative("true", kind: .string, at: [.key("enabled")])
        #expect(text.contains("enabled: \"true\""))
        #expect(try ComposeDocument(text).nativeField(at: [.key("enabled")]).kind == .string)
        let number = try ComposeDocument(text).settingNative("12", kind: .number, at: [.key("count")])
        #expect(try ComposeDocument(number).nativeField(at: [.key("count")]).kind == .number)
        #expect(throws: (any Error).self) { try ComposeDocument(number).settingNative("12 # comment", kind: .number, at: [.key("count")]) }
    }
    @Test func nativeMultilineTextRemainsEditable() throws {
        let text = try ComposeDocument("value: initial\n").settingNative("first\nsecond", kind: .string, at: [.key("value")])
        let field = try ComposeDocument(text).nativeField(at: [.key("value")])
        #expect(field.kind == .string)
        #expect(field.value == "first\nsecond")
        #expect(try ComposeDocument(text).settingNative(field.value, kind: field.kind, at: field.path) == text)
    }
    @Test func referencesAndDuplicateFlowKeysFailClosed() throws {
        let document = try ComposeDocument("options:\n  shared: &shared {key: value}\nother: *shared\n")
        #expect(throws: (any Error).self) { try document.settingNative("", kind: .null, at: [.key("options")]) }
        #expect(throws: (any Error).self) { try document.removingNative(at: [.key("options")]) }
        #expect(throws: (any Error).self) { try ComposeDocument("options: {key: one, key: two}") }
    }
    @Test func shortNetworksConvertAndAcceptStaticOptions() throws {
        for source in ["services:\n  web:\n    networks:\n      - front # first\n      - back\n", "services:\r\n  web:\r\n    networks: [front, # first\r\n      back] # networks\r\n"] {
            let path = ["services", "web", "networks"]
            let converted = try ComposeDocument(source).convertingNetworkAttachments(at: path)
            let changed = try ComposeDocument(converted).setting("'172.20.0.2'", at: path + ["front", "ipv4_address"])
            #expect(try ComposeDocument(changed).scalar(at: path + ["front", "ipv4_address"]) == "172.20.0.2")
            #expect(changed.contains("# first"))
        }
    }
    @Test func duplicateNetworksDoNotConvert() throws {
        let source = "services:\n  web:\n    networks: [front, front]\n"
        #expect(throws: (any Error).self) { try ComposeDocument(source).convertingNetworkAttachments(at: ["services", "web", "networks"]) }
    }

    @Test func emptyNetworksConvertToAnEditableMapping() throws {
        let path = ["services", "web", "networks"]
        let source = "services:\n  web:\n    networks: [] # keep\n"
        let converted = try ComposeDocument(source).convertingNetworkAttachments(at: path)
        let added = try ComposeDocument(converted).setting("{}", at: path + ["front"])
        #expect(try ComposeDocument(added).keys(at: path) == ["front"])
        #expect(added.contains("# keep"))
    }

    @Test func flowServicesAppearInNativeNavigation() throws {
        let source = "services: {web: {image: nginx}, db: {image: postgres}}\n"
        #expect(try ComposeDocument(source).services == ["web", "db"])
    }

    @Test func compactSequenceMappingRemovalRetainsTheOuterItem() throws {
        let source = "ports:\n  - target: 80 # remove target\n    published: 8080\n    protocol: tcp\n  - target: 443\n"
        let edited = try ComposeDocument(source).removingNative(at: [.key("ports"), .index(0), .key("target")])
        let document = try ComposeDocument(edited)
        #expect(document.nativeFields(at: [.key("ports")]).count == 2)
        #expect(document.nativeField(at: [.key("ports"), .index(0), .key("published")]).value == "8080")
        #expect(document.nativeField(at: [.key("ports"), .index(1), .key("target")]).value == "443")
        #expect(edited.contains("# remove target"))
    }

    @Test func implicitFlowNullKeysAreEditableAndDeduplicated() throws {
        let source = "environment: {TOKEN, OTHER: explicit} # keep\n"
        let document = try ComposeDocument(source)
        let token: [ComposeFieldPathComponent] = [.key("environment"), .key("TOKEN")]
        #expect(document.nativeFields(at: [.key("environment")]).map(\.name) == ["TOKEN", "OTHER"])
        #expect(try document.settingNative("", kind: .null, at: token) == source)
        #expect(try document.settingNative("secret", kind: .string, at: token) == "environment: {TOKEN: \"secret\", OTHER: explicit} # keep\n")
        #expect(throws: (any Error).self) { try ComposeDocument("environment: {TOKEN, TOKEN: duplicate}\n") }
    }
}
