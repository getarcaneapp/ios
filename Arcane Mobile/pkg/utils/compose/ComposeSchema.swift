import Foundation

/// Field suggestions from the bundled upstream Compose schema, never a serialization format.
nonisolated enum ComposeSchema {
    static let revision = "914ec15d1fa498969c0df5c1d672306db3256089"
    private static let root: ComposeSchemaValue? = {
        guard let compose = load("compose-spec") else { return nil }
        guard let metadata = load("arcane-metadata") else { return compose }
        var root = compose.object
        var properties = root["properties"]?.object ?? [:]
        properties["x-arcane"] = metadata.object["project"]
        root["properties"] = .object(properties)
        var definitions = root["$defs"]?.object ?? [:]
        var service = definitions["service"]?.object ?? [:]
        var serviceProperties = service["properties"]?.object ?? [:]
        serviceProperties["x-arcane"] = metadata.object["service"]
        service["properties"] = .object(serviceProperties)
        definitions["service"] = .object(service)
        root["$defs"] = .object(definitions)
        return .object(root)
    }()

    private static func load(_ resource: String) -> ComposeSchemaValue? {
        let bundles = [Bundle.main, Bundle(for: ComposeSchemaResourceMarker.self)]
        for bundle in bundles {
            for directory in ["ComposeSchema", "Resources/ComposeSchema", ""] {
                if let url = bundle.url(forResource: resource, withExtension: "json", subdirectory: directory),
                   let data = try? Data(contentsOf: url), let schema = try? JSONDecoder().decode(ComposeSchemaValue.self, from: data) {
                    return schema
                }
            }
        }
        return nil
    }

    static func fields(at path: [ComposeFieldPathComponent]) -> [ComposeSchemaField] {
        let variants = schemas(at: path)
        let names = Set(variants.flatMap { $0.object["properties"]?.object.keys.map { $0 } ?? [] })
        return names.sorted().compactMap { name in
            let nodes = variants.compactMap { $0.object["properties"]?.object[name] }
            return field(name: name, schemas: nodes)
        }
    }

    static func value(at path: [ComposeFieldPathComponent]) -> ComposeSchemaField? {
        let name: String
        if case .key(let key) = path.last { name = key } else { name = "Value" }
        return field(name: name, schemas: schemas(at: path))
    }

    private static func schemas(at path: [ComposeFieldPathComponent]) -> [ComposeSchemaValue] {
        guard let root else { return [] }
        var current = expanded(root)
        for component in path {
            current = current.flatMap { schema -> [ComposeSchemaValue] in
                let node = schema.object
                switch component {
                case .key(let key):
                    var matches: [ComposeSchemaValue] = []
                    if let explicit = node["properties"]?.object[key] { matches.append(explicit) }
                    for (pattern, value) in node["patternProperties"]?.object ?? [:] {
                        if key.range(of: pattern, options: .regularExpression) != nil { matches.append(value) }
                    }
                    if matches.isEmpty, let additional = node["additionalProperties"] {
                        if case .object = additional { matches.append(additional) }
                        else if case .boolean(true) = additional { matches.append(.object([:])) }
                    }
                    return matches.flatMap { expanded($0) }
                case .index(let index):
                    guard index >= 0, let items = node["items"] else { return [] }
                    if case .array(let tuple) = items {
                        guard tuple.indices.contains(index) else { return [] }
                        return expanded(tuple[index])
                    }
                    return expanded(items)
                }
            }
        }
        return current
    }

    private static func expanded(_ schema: ComposeSchemaValue, references: Set<String> = []) -> [ComposeSchemaValue] {
        var result = [schema]
        let node = schema.object
        if let reference = node["$ref"]?.string, !references.contains(reference), let target = resolve(reference) {
            result += expanded(target, references: references.union([reference]))
        }
        for combinator in ["allOf", "oneOf", "anyOf"] {
            for branch in node[combinator]?.array ?? [] { result += expanded(branch, references: references) }
        }
        return result
    }

    private static func resolve(_ reference: String) -> ComposeSchemaValue? {
        guard reference.hasPrefix("#/"), var value = root else { return nil }
        for token in reference.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false) {
            let key = token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            guard let next = value.object[key] else { return nil }
            value = next
        }
        return value
    }

    private static func field(name: String, schemas: [ComposeSchemaValue]) -> ComposeSchemaField? {
        guard !schemas.isEmpty else { return nil }
        let variants = schemas.flatMap { expanded($0) }
        var kinds: [ComposeNativeKind] = []
        var choices: [String] = []
        var description = ""
        for variant in variants {
            let node = variant.object
            if description.isEmpty { description = node["description"]?.string ?? "" }
            let types = node["type"].map { $0.string.map { [$0] } ?? $0.array.compactMap(\.string) } ?? []
            for type in types {
                let kind: ComposeNativeKind?
                switch type {
                case "string": kind = .string
                case "integer", "number": kind = .number
                case "boolean": kind = .boolean
                case "null": kind = .null
                case "object": kind = .mapping
                case "array": kind = .sequence
                default: kind = nil
                }
                if let kind, !kinds.contains(kind) { kinds.append(kind) }
            }
            if node["properties"] != nil, !kinds.contains(.mapping) { kinds.append(.mapping) }
            if node["items"] != nil, !kinds.contains(.sequence) { kinds.append(.sequence) }
            let literals = (node["enum"]?.array.compactMap(\.literal) ?? []) + (node["const"]?.literal.map { [$0] } ?? [])
            for choice in literals where !choices.contains(choice) { choices.append(choice) }
        }
        if kinds.isEmpty { kinds = ComposeNativeKind.editableCases }
        return ComposeSchemaField(name: name, description: description, kinds: kinds, enumValues: choices)
    }
}
