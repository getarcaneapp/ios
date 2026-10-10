import Testing

@testable import Arcane_Mobile

@Suite struct ComposeEntryNativeTransitionTests {
    @Test func portEditsSurviveNativeSettingsAndFurtherBasicEdits() throws {
        let original = "target: 80 # container\npublished: '8080'\nmode: ingress\nname: public"
        var basic = try ComposeEntryDraft(raw: original, kind: .port)
        basic.source = "8081"
        let firstEdit = try basic.yaml(kind: .port)
        let wrapper =
            "entry:\n"
            + firstEdit.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(
                separator: "\n")
        let nativeEdit = try ComposeDocument(wrapper).settingNative(
            "host", kind: .string, at: [.key("entry"), .key("mode")])
        let nativeRaw = try #require(ComposeDocument(nativeEdit).rawValue(at: ["entry"]))
        var resumed = try ComposeEntryDraft(raw: nativeRaw, kind: .port)
        resumed.target = "81"
        let result = try resumed.yaml(kind: .port)
        let document = try ComposeDocument(result)
        #expect(document.scalar(at: ["published"]) == "8081")
        #expect(document.scalar(at: ["target"]) == "81")
        #expect(document.scalar(at: ["mode"]) == "host")
        #expect(document.scalar(at: ["name"]) == "public")
        #expect(result.contains("# container"))
    }

    @Test func mountEditsSurviveNativeSettingsAndFurtherBasicEdits() throws {
        let original = "type: bind\nsource: /srv/data\ntarget: /data\nbind:\n  propagation: rprivate"
        var basic = try ComposeEntryDraft(raw: original, kind: .mount)
        basic.target = "/storage"
        let firstEdit = try basic.yaml(kind: .mount)
        let wrapper =
            "entry:\n"
            + firstEdit.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(
                separator: "\n")
        let nativeEdit = try ComposeDocument(wrapper).settingNative(
            "rshared", kind: .string, at: [.key("entry"), .key("bind"), .key("propagation")])
        let nativeRaw = try #require(ComposeDocument(nativeEdit).rawValue(at: ["entry"]))
        var resumed = try ComposeEntryDraft(raw: nativeRaw, kind: .mount)
        resumed.readOnly = true
        let document = try ComposeDocument(resumed.yaml(kind: .mount))
        #expect(document.scalar(at: ["source"]) == "/srv/data")
        #expect(document.scalar(at: ["target"]) == "/storage")
        #expect(document.scalar(at: ["read_only"]) == "true")
        #expect(document.scalar(at: ["bind", "propagation"]) == "rshared")
    }

    @Test(arguments: [
        "target: 80 # container\npublished: '8080'\nmode: host",
        "type: bind\nsource: /srv/data\ntarget: /data\nbind:\n  propagation: rprivate",
    ])
    func openingNativeSettingsWithoutEditingPreservesEntry(raw: String) throws {
        let kind: ComposeEntryKind = raw.hasPrefix("target:") ? .port : .mount
        let basicRaw = try ComposeEntryDraft(raw: raw, kind: kind).yaml(kind: kind)
        let wrapper =
            "entry:\n"
            + basicRaw.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(
                separator: "\n")
        let extracted = try #require(ComposeDocument(wrapper).rawValue(at: ["entry"]))
        #expect(try ComposeEntryDraft(raw: extracted, kind: kind).yaml(kind: kind) == raw)
    }
}
