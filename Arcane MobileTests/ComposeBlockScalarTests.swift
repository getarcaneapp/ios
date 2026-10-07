import Testing
@testable import Arcane_Mobile

@Suite struct ComposeBlockScalarTests {
    @Test func literalAndFoldedValuesFollowIndentationAndChomping() throws {
        let fixtures: [(String, String)] = [
            ("value: |\n  first\n  second\nnext: keep\n", "first\nsecond\n"),
            ("value: |-\n  first\n  second\n\nnext: keep\n", "first\nsecond"),
            ("value: |+\n  first\n\nnext: keep\n", "first\n\n"),
            ("value: |\n  first", "first"),
            ("value: |\n\nnext: keep\n", ""),
            ("value: |+\n\nnext: keep\n", "\n"),
            ("value: |\n  \n   \nnext: keep\n", ""),
            ("value: |+\n  \n   \nnext: keep\n", "\n\n"),
            ("value: |2-\n    indented\n  plain\n", "  indented\nplain"),
            ("value: >-\n  first\n  second\n", "first second"),
            ("value: >\n  first\n\n  second\n", "first\nsecond\n"),
            ("value: >+\n  first\n\n\n  second\n\n", "first\n\nsecond\n\n"),
            ("value: >-\n  first\n    indented\n  last\n", "first\n  indented\nlast"),
            ("value: >-\n  first\n\n    indented\n\n  last\n", "first\n\n  indented\n\nlast"),
            ("value: >\n\n  first\n  second\n", "\nfirst second\n"),
            ("value: | # retained\r\n  café 🐳\r\n  ${VALUE}\r\n\r\nnext: keep\r\n", "café 🐳\n${VALUE}\n"),
        ]
        for (source, expected) in fixtures {
            let document = try ComposeDocument(source)
            let field = document.nativeField(at: [.key("value")])
            #expect(field.kind == .string, "\(source)")
            #expect(field.value == expected, "\(source)")
            #expect(try document.settingNative(expected, kind: .string, at: field.path) == source, "Unchanged block must preserve all bytes: \(source)")
        }
    }

    @Test func editedBlocksPreserveRequestedValueAndSurroundingSource() throws {
        let originals = [
            "value: | # script\n  old\nnext: untouched # tail\n",
            "value: >- # script\n  old\n  wrapped\n\nnext: untouched # tail\n",
            "value: |2+ # script\r\n  old\r\n\r\nnext: untouched # tail\r\n",
        ]
        let values = ["", "single", "first\nsecond", "first\nsecond\n", "first\n\n", "\n", "\n\n", "  leading\n  spaces\n", "\n  spaces\n", "${KEEP}\n# content\n", "\tleading\n", "foo\rbar"]
        for source in originals {
            for value in values {
                let changed = try ComposeDocument(source).settingNative(value, kind: .string, at: [.key("value")])
                let reparsed = try ComposeDocument(changed)
                #expect(reparsed.nativeField(at: [.key("value")]).value == value, "\(changed)")
                #expect(changed.contains("# script"))
                #expect(changed.hasSuffix(source.contains("\r\n") ? "next: untouched # tail\r\n" : "next: untouched # tail\n"))
                #expect(try reparsed.settingNative(value, kind: .string, at: [.key("value")]) == changed)
            }
        }
    }

    @Test func commandAndConfigFixturesRemainSourceBacked() throws {
        let source = """
        name: operator
        services:
          web:
            image: nginx:${TAG:-latest}
            command: >-
              sh -c
              'echo ${MESSAGE};
              sleep 5'
            healthcheck: {test: [CMD, curl, '-f', 'http://localhost'], retries: 3}
            configs: [{source: app, target: /etc/app.conf}]
        configs:
          app:
            content: | # application settings
              [server]
              token=${TOKEN}
              # this belongs to the config
        x-extension: {preserve: true}

        """
        let command: [ComposeFieldPathComponent] = [.key("services"), .key("web"), .key("command")]
        let config: [ComposeFieldPathComponent] = [.key("configs"), .key("app"), .key("content")]
        let document = try ComposeDocument(source)
        #expect(document.nativeField(at: command).value == "sh -c 'echo ${MESSAGE}; sleep 5'")
        #expect(document.nativeField(at: config).value == "[server]\ntoken=${TOKEN}\n# this belongs to the config\n")
        let changed = try document.settingNative("[server]\ntoken=${NEW_TOKEN}\n", kind: .string, at: config)
        #expect(changed.hasPrefix(String(source.prefix(upTo: try #require(source.range(of: "    content:")) .lowerBound))))
        #expect(try ComposeDocument(changed).nativeField(at: command).value == document.nativeField(at: command).value)
        #expect(changed.hasSuffix("x-extension: {preserve: true}\n"))
    }

    @Test func sequenceBlockAndAnchorDefinitionsEditWithoutExpandingReferences() throws {
        let source = "x-shared: &shared\n  image: nginx\n  restart: always\nx-command: &command |-\n  echo old\nservices:\n  web:\n    <<: *shared\n    command: *command\n    entrypoint:\n      - sh\n      - -c\n      - |2-\n          echo nested\n"
        let command: [ComposeFieldPathComponent] = [.key("x-command")]
        let document = try ComposeDocument(source)
        #expect(document.nativeField(at: command).value == "echo old")
        let anchored = try document.settingNative("echo new", kind: .string, at: command)
        #expect(anchored.contains("x-command: &command |-\n  echo new\n"))
        #expect(anchored.contains("command: *command"))
        let mapping = try ComposeDocument(anchored).settingNative("alpine", kind: .string, at: [.key("x-shared"), .key("image")])
        #expect(mapping.contains("x-shared: &shared\n  image: \"alpine\"\n"))
        #expect(mapping.contains("<<: *shared"))
        #expect(throws: (any Error).self) { try ComposeDocument(mapping).removingNative(at: [.key("x-shared")]) }
        #expect(throws: (any Error).self) { try ComposeDocument(mapping).settingNative("12", kind: .number, at: command) }
        // A separate ordinary service exercises sequence block scalars without traversing a merge.
        let sequence = try ComposeDocument("items:\n  - |2-\n     indented\n  - keep\n")
        #expect(sequence.nativeField(at: [.key("items"), .index(0)]).value == " indented")
        let edited = try sequence.settingNative("new\nline", kind: .string, at: [.key("items"), .index(0)])
        #expect(try ComposeDocument(edited).nativeField(at: [.key("items"), .index(0)]).value == "new\nline")
        #expect(edited.hasSuffix("  - keep\n"))
    }

    @Test func scalarAnchorNameAndAliasesSurviveTargetEdits() throws {
        let source = "image: &image nginx # shared\nother: *image\n"
        let document = try ComposeDocument(source)
        #expect(document.nativeField(at: [.key("image")]).kind == .string)
        #expect(try document.settingNative("alpine", kind: .string, at: [.key("image")]) == "image: &image \"alpine\" # shared\nother: *image\n")
        #expect(document.nativeField(at: [.key("other")]).kind == .unsupported)
        #expect(throws: (any Error).self) { try document.settingNative("changed", kind: .string, at: [.key("other")]) }
        #expect(throws: (any Error).self) { try document.removingNative(at: [.key("image")]) }
    }

    @Test func mergedServicesExposeOnlyExplicitFieldsWithoutExpandingAliases() throws {
        let source = "x-base: &base\n  restart: always\nservices:\n  web:\n    <<: *base\n    image: nginx\n    command: |-\n      echo original\n"
        let service: [ComposeFieldPathComponent] = [.key("services"), .key("web")]
        let document = try ComposeDocument(source)
        #expect(document.nativeFields(at: service).map(\.name) == ["<<", "image", "command"])
        #expect(document.nativeField(at: service + [.key("<<")]).kind == .unsupported)
        let edited = try document.settingNative("echo edited", kind: .string, at: service + [.key("command")])
        #expect(edited.contains("    <<: *base\n    image: nginx\n"))
        let override = try ComposeDocument(edited).addingNative("unless-stopped", kind: .string, key: "restart", at: service)
        #expect(override.hasPrefix("x-base: &base\n  restart: always\n"))
        #expect(override.contains("    <<: *base\n"))
        #expect(throws: (any Error).self) { try document.removingNative(at: service + [.key("<<")]) }
        #expect(throws: (any Error).self) { try document.settingNative("", kind: .mapping, at: service + [.key("<<")]) }
    }

    @Test func implicitNullFieldsAndItemsHaveByteIdenticalNoOps() throws {
        let source = "environment:\n  PASSTHROUGH: # host variable\nitems:\n  - # empty\n  - explicit\n"
        let document = try ComposeDocument(source)
        for path: [ComposeFieldPathComponent] in [[.key("environment"), .key("PASSTHROUGH")], [.key("items"), .index(0)]] {
            #expect(document.nativeField(at: path).kind == .null)
            #expect(try document.settingNative("", kind: .null, at: path) == source)
        }
    }

    @Test func composeOverrideAndResetTagsKeepTheirSpellingAndMeaning() throws {
        let source = "services:\n  web:\n    ports: !override [\"8080:80\", \"8443:443\"] # replacements\n    environment:\n      TOKEN: !reset null # cleared\n"
        let ports: [ComposeFieldPathComponent] = [.key("services"), .key("web"), .key("ports")]
        let reset: [ComposeFieldPathComponent] = [.key("services"), .key("web"), .key("environment"), .key("TOKEN")]
        let document = try ComposeDocument(source)
        #expect(document.nativeField(at: ports).kind == .sequence)
        #expect(try document.settingNative("", kind: .null, at: reset) == source)
        let changed = try document.settingNative("9090:80", kind: .string, at: ports + [.index(0)])
        #expect(changed == source.replacingOccurrences(of: "8080:80", with: "9090:80"))
        let added = try ComposeDocument(changed).addingNative("9000:9000", kind: .string, key: nil, at: ports)
        #expect(added.contains("ports: !override ["))
        #expect(added.contains("TOKEN: !reset null # cleared"))
        #expect(try ComposeDocument(added).nativeFields(at: ports).count == 3)
        let custom = try ComposeDocument("items: [!custom value]\n")
        #expect(custom.nativeField(at: [.key("items"), .index(0)]).kind == .unsupported)
    }
}
