import Foundation
import Testing
@testable import Arcane_Mobile

@Suite("Compose schema field suggestions")
struct ComposeSchemaTests {
    private let service: [ComposeFieldPathComponent] = [.key("services"), .key("app")]

    @Test func serviceIncludesInheritedAndNewSpecificationFields() throws {
        let fields = ComposeSchema.fields(at: service)
        let names = Set(fields.map(\.name))
        for expected in ["image", "build", "deploy", "ports", "networks", "healthcheck", "env_file", "models", "post_start", "pre_stop"] {
            #expect(names.contains(expected), "Missing service field: \(expected)")
        }
        #expect(fields.allSatisfy { !$0.kinds.isEmpty })
        #expect(names.count == fields.count)
        let retries = try #require(ComposeSchema.value(at: service + [.key("healthcheck"), .key("retries")]))
        #expect(Set(retries.kinds) == [.number, .string])
        #expect(retries.preferredKind == .string)
        #expect(!retries.description.isEmpty)
    }

    @Test func unionPathsResolveListItemsAndMappingEntries() throws {
        let envFile = service + [.key("env_file")]
        #expect(Set(try #require(ComposeSchema.value(at: envFile)).kinds) == [.string, .sequence])
        #expect(Set(try #require(ComposeSchema.value(at: envFile + [.index(0)])).kinds) == [.string, .mapping])
        #expect(Set(ComposeSchema.fields(at: envFile + [.index(0)]).map(\.name)) == ["path", "format", "required"])
        let ports = service + [.key("ports"), .index(0)]
        #expect(Set(try #require(ComposeSchema.value(at: ports)).kinds) == [.number, .string, .mapping])
        #expect(ComposeSchema.fields(at: ports).contains { $0.name == "target" })
        let mounts = service + [.key("volumes"), .index(0)]
        #expect(ComposeSchema.fields(at: mounts).contains { $0.name == "bind" })
        #expect(ComposeSchema.fields(at: mounts + [.key("bind")]).contains { $0.name == "create_host_path" })
        let attachments = service + [.key("networks"), .key("frontend")]
        #expect(ComposeSchema.fields(at: attachments).contains { $0.name == "ipv4_address" })
        #expect(ComposeSchema.value(at: service + [.key("healthcheck"), .key("test"), .index(2)])?.kinds == [.string])
    }

    @Test func rootResourcesAndDictionaryValuesResolve() throws {
        for resource in ["networks", "volumes", "secrets", "configs", "models", "jobs"] {
            #expect(!ComposeSchema.fields(at: [.key(resource), .key("example")]).isEmpty, "Missing resource schema: \(resource)")
        }
        #expect(ComposeSchema.fields(at: [.key("models"), .key("example")]).contains { $0.name == "runtime_flags" })
        #expect(ComposeSchema.fields(at: [.key("configs"), .key("example")]).contains { $0.name == "content" })
        #expect(ComposeSchema.value(at: service + [.key("labels"), .key("example.test.label")]) != nil)
        #expect(ComposeSchema.value(at: service + [.key("x-example")])?.kinds == ComposeNativeKind.editableCases)
        #expect(ComposeSchema.value(at: service + [.key("not_a_compose_field")]) == nil)
        #expect(ComposeSchema.value(at: service + [.key("ports"), .index(-1)]) == nil)
    }

    @Test func officialPropertiesAreReachableThroughReferencesAndCombinators() throws {
        let root = try snapshot()
        var checked = 0
        func expand(_ node: [String: Any], seen: Set<String>) -> [[String: Any]] {
            var result = [node]
            if let ref = node["$ref"] as? String, !seen.contains(ref) {
                var target: Any = root
                for part in ref.dropFirst(2).split(separator: "/") {
                    target = (target as? [String: Any])?[String(part)] ?? [:]
                }
                if let target = target as? [String: Any] { result += expand(target, seen: seen.union([ref])) }
            }
            for key in ["allOf", "oneOf", "anyOf"] {
                for branch in node[key] as? [[String: Any]] ?? [] { result += expand(branch, seen: seen) }
            }
            return result
        }
        func visit(_ node: [String: Any], path: [ComposeFieldPathComponent], depth: Int) {
            guard depth < 12 else { return }
            let variants = expand(node, seen: [])
            let suggested = Set(ComposeSchema.fields(at: path).map(\.name))
            for variant in variants {
                for (name, child) in variant["properties"] as? [String: [String: Any]] ?? [:] {
                    checked += 1
                    #expect(suggested.contains(name), "Missing schema property: \(path) / \(name)")
                    #expect(ComposeSchema.value(at: path + [.key(name)]) != nil)
                    visit(child, path: path + [.key(name)], depth: depth + 1)
                }
                for (pattern, child) in variant["patternProperties"] as? [String: [String: Any]] ?? [:] {
                    let sample = pattern.hasPrefix("^x-") ? "x-example" : "example"
                    if sample.range(of: pattern, options: .regularExpression) != nil {
                        visit(child, path: path + [.key(sample)], depth: depth + 1)
                    }
                }
                if let item = variant["items"] as? [String: Any] { visit(item, path: path + [.index(0)], depth: depth + 1) }
                if let additional = variant["additionalProperties"] as? [String: Any] { visit(additional, path: path + [.key("example")], depth: depth + 1) }
            }
        }
        visit(root, path: [], depth: 0)
        #expect(checked > 300)
    }

    private func snapshot() throws -> [String: Any] {
        let bundles = [Bundle.main, Bundle(for: ComposeSchemaResourceMarker.self)]
        let url = try #require(bundles.lazy.compactMap { bundle in
            ["ComposeSchema", "Resources/ComposeSchema", ""].lazy.compactMap {
                bundle.url(forResource: "compose-spec", withExtension: "json", subdirectory: $0)
            }.first
        }.first)
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}
