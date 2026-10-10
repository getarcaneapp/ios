import Testing

@testable import Arcane_Mobile

@Suite struct ComposeEntryDraftTests {
    @Test(arguments: ["'80:80'", "'127.0.0.1:8080:80/udp'", "'8000-8010:9000-9010'"])
    func untouchedPortsPreserveSpelling(raw: String) throws {
        #expect(try ComposeEntryDraft(raw: raw, kind: .port).yaml(kind: .port) == raw)
    }
    @Test(arguments: ["'data:/data:rw'", "'/tmp:/data:ro'", "'/data'"])
    func untouchedMountsPreserveSpelling(raw: String) throws {
        #expect(try ComposeEntryDraft(raw: raw, kind: .mount).yaml(kind: .mount) == raw)
    }
    @Test func passthroughVariableRemainsUnset() throws {
        #expect(try ComposeEntryDraft(raw: "'TOKEN'", kind: .keyValue).yaml(kind: .keyValue) == "'TOKEN'")
    }
    @Test func editedKeyValuePreservesEquals() throws {
        var draft = try ComposeEntryDraft(raw: "'TOKEN=a=b'", kind: .keyValue)
        #expect(draft.target == "a=b")
        draft.target = "c=d"
        #expect(try draft.yaml(kind: .keyValue) == "\"TOKEN=c=d\"")
    }
    @Test func longPortPreservesUnknownFieldsAndComments() throws {
        let raw = "target: 80 # container\npublished: '8080'\nmode: host\nname: public"
        var draft = try ComposeEntryDraft(raw: raw, kind: .port)
        #expect(try draft.yaml(kind: .port) == raw)
        draft.source = "8081"
        let changed = try draft.yaml(kind: .port)
        #expect(changed.contains("target: 80 # container"))
        #expect(changed.contains("mode: host\nname: public"))
        #expect(!changed.contains("protocol"))
        #expect(try ComposeDocument(changed).scalar(at: ["published"]) == "8081")
    }
    @Test func readonlyCapitalizationIsUnderstood() throws {
        let raw = "type: bind\nsource: /tmp\ntarget: /data\nread_only: True"
        let draft = try ComposeEntryDraft(raw: raw, kind: .mount)
        #expect(draft.readOnly)
        #expect(try draft.yaml(kind: .mount) == raw)
    }
    @Test func complexEntriesRequireYaml() {
        for raw in ["'${PORT}:80'", "'[::1]:80:80'"] {
            #expect(throws: (any Error).self) { try ComposeEntryDraft(raw: raw, kind: .port) }
        }
        #expect(throws: (any Error).self) { try ComposeEntryDraft(raw: "'/tmp:/data:ro,z'", kind: .mount) }
    }
    @Test func rejectsInvalidNewInputs() {
        var draft = ComposeEntryDraft()
        draft.target = "65536"
        #expect(throws: (any Error).self) { try draft.yaml(kind: .port) }
        draft.target = "relative/path"
        #expect(throws: (any Error).self) { try draft.yaml(kind: .mount) }
    }

    @Test func editingLongMountSourceUpdatesType() throws {
        var bind = try ComposeEntryDraft(raw: "type: bind\nsource: /tmp\ntarget: /data\nread_only: true", kind: .mount)
        bind.source = "data"
        let volume = try bind.yaml(kind: .mount)
        #expect(try ComposeDocument(volume).scalar(at: ["type"]) == "volume")
        #expect(volume.contains("target: /data\nread_only: true"))
        var back = try ComposeEntryDraft(raw: volume, kind: .mount)
        back.source = "./data"
        #expect(try ComposeDocument(back.yaml(kind: .mount)).scalar(at: ["type"]) == "bind")
    }
    @Test(arguments: ["bind:\n  propagation: rshared", "volume:\n  nocopy: true", "tmpfs:\n  size: 1024"])
    func changingMountTypeWithSpecialOptionsRequiresYaml(options: String) throws {
        var draft = try ComposeEntryDraft(raw: "type: bind\nsource: /tmp\ntarget: /data\n" + options, kind: .mount)
        draft.source = "data"
        #expect(throws: (any Error).self) { try draft.yaml(kind: .mount) }
    }
}
