import Testing
@testable import Arcane_Mobile

@Suite("Arcane Compose metadata")
struct ComposeArcaneMetadataTests {
    private let metadata: [ComposeFieldPathComponent] = [.key("x-arcane")]
    private let serviceMetadata: [ComposeFieldPathComponent] = [.key("services"), .key("web"), .key("x-arcane")]

    @Test func rootAndServiceMetadataOfferTheirSupportedFields() throws {
        #expect(ComposeSchema.fields(at: []).contains { $0.name == "x-arcane" && $0.kinds == [.mapping] })
        #expect(ComposeSchema.fields(at: [.key("services"), .key("web")]).contains { $0.name == "x-arcane" && $0.kinds == [.mapping] })
        #expect(Set(ComposeSchema.fields(at: metadata).map(\.name)) == ["icon", "icons", "icon-light", "icon-dark", "hidden", "urls", "tags", "updater"])
        #expect(Set(ComposeSchema.fields(at: serviceMetadata).map(\.name)) == ["icon", "icons", "icon-light", "icon-dark", "hidden", "updater"])
        for path in [metadata, serviceMetadata] {
            #expect(try #require(ComposeSchema.value(at: path + [.key("hidden")])).kinds == [.boolean])
            #expect(Set(try #require(ComposeSchema.value(at: path + [.key("icons")])).kinds) == [.string, .sequence])
            #expect(try #require(ComposeSchema.value(at: path + [.key("icons"), .index(0)])).kinds == [.string])
        }
    }

    @Test func updaterAndTagItemsHaveTypedFieldsAndEnums() throws {
        for path in [metadata, serviceMetadata] {
            let updater = path + [.key("updater")]
            #expect(Set(ComposeSchema.fields(at: updater).map(\.name)) == ["enabled", "strategy", "constraint", "tag-pattern"])
            #expect(try #require(ComposeSchema.value(at: updater + [.key("enabled")])).kinds == [.boolean])
            let strategy = try #require(ComposeSchema.value(at: updater + [.key("strategy")]))
            #expect(strategy.kinds == [.string])
            #expect(Set(strategy.enumValues) == ["auto", "tag", "digest"])
            for key in ["constraint", "tag-pattern"] {
                #expect(try #require(ComposeSchema.value(at: updater + [.key(key)])).kinds == [.string])
            }
        }
        let tag = metadata + [.key("tags"), .index(0)]
        #expect(try #require(ComposeSchema.value(at: tag)).kinds == [.mapping])
        #expect(Set(ComposeSchema.fields(at: tag).map(\.name)) == ["name", "color"])
        #expect(try #require(ComposeSchema.value(at: tag + [.key("name")])).kinds == [.string])
        let color = try #require(ComposeSchema.value(at: tag + [.key("color")]))
        #expect(color.kinds == [.string])
        #expect(Set(color.enumValues) == ["gray", "purple", "blue", "green", "yellow", "orange", "red", "pink"])
    }

    @Test func nativeMetadataCreationPreservesExistingComposeSourceAndNoOpEdits() throws {
        let source = "# project metadata\nservices:\n  web:\n    image: nginx:latest # keep image\nx-extra: ${KEEP}\n"
        var edited = try ComposeDocument(source).addingNative("", kind: .mapping, key: "x-arcane", at: [])
        edited = try ComposeDocument(edited).addingNative("", kind: .mapping, key: "updater", at: metadata)
        let updater = metadata + [.key("updater")]
        edited = try ComposeDocument(edited).addingNative("true", kind: .boolean, key: "enabled", at: updater)
        edited = try ComposeDocument(edited).addingNative("digest", kind: .string, key: "strategy", at: updater)
        edited = try ComposeDocument(edited).addingNative("", kind: .sequence, key: "tags", at: metadata)
        let tags = metadata + [.key("tags")]
        edited = try ComposeDocument(edited).addingNative("", kind: .mapping, key: nil, at: tags)
        let tag = tags + [.index(0)]
        edited = try ComposeDocument(edited).addingNative("Production", kind: .string, key: "name", at: tag)
        edited = try ComposeDocument(edited).addingNative("green", kind: .string, key: "color", at: tag)
        #expect(edited.contains(source))
        let document = try ComposeDocument(edited)
        #expect(document.nativeField(at: updater + [.key("enabled")]).kind == .boolean)
        #expect(document.nativeField(at: tag + [.key("name")]).value == "Production")
        for path in [updater + [.key("enabled")], updater + [.key("strategy")], tag + [.key("name")], tag + [.key("color")]] {
            let field = document.nativeField(at: path)
            #expect(try document.settingNative(field.value, kind: field.kind, at: path) == edited)
        }
    }
}
