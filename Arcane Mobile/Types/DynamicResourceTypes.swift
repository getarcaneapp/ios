import Foundation

nonisolated enum AnyJSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: AnyJSONValue])
    case array([AnyJSONValue])
    case null

    nonisolated init(from decoder: any Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? single.decode(Double.self) {
            self = .number(value)
        } else if let value = try? single.decode(String.self) {
            self = .string(value)
        } else if let value = try? single.decode([AnyJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try single.decode([String: AnyJSONValue].self))
        }
    }

    nonisolated func encode(to encoder: any Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .string(let value): try single.encode(value)
        case .number(let value): try single.encode(value)
        case .bool(let value): try single.encode(value)
        case .object(let value): try single.encode(value)
        case .array(let value): try single.encode(value)
        case .null: try single.encodeNil()
        }
    }

    var displayString: String {
        switch self {
        case .string(let value): return value
        case .number(let value):
            let intValue = Int64(value)
            return Double(intValue) == value ? "\(intValue)" : "\(value)"
        case .bool(let value): return value ? "Yes" : "No"
        case .object(let value): return "\(value.count) fields"
        case .array(let value): return "\(value.count) items"
        case .null: return "None"
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var objectValue: [String: AnyJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [AnyJSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

nonisolated struct DynamicResource: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let values: [String: AnyJSONValue]

    nonisolated init(id: String, values: [String: AnyJSONValue]) {
        self.id = id
        self.values = values
    }

    nonisolated init(from decoder: any Decoder) throws {
        let values = try [String: AnyJSONValue](from: decoder)
        self.values = values
        self.id = Self.resolveID(from: values)
    }

    nonisolated func encode(to encoder: any Encoder) throws {
        try values.encode(to: encoder)
    }

    var title: String {
        for key in ["name", "Name", "title", "Title", "id", "ID", "serviceName", "containerName", "repositoryUrl", "url"] {
            if let value = values[key]?.displayString, !value.isEmpty { return value }
        }
        return id
    }

    var subtitle: String {
        for key in ["description", "status", "state", "image", "path", "url", "message", "type", "eventType"] {
            if let value = values[key]?.displayString, !value.isEmpty, value != title { return value }
        }
        return id
    }

    var statusText: String? {
        for key in ["status", "state", "enabled", "isEnabled", "active", "isActive", "availability"] {
            if let value = values[key] { return value.displayString }
        }
        return nil
    }

    var sortedDetails: [(String, AnyJSONValue)] {
        values
            .filter { !$0.key.localizedCaseInsensitiveContains("password") && !$0.key.localizedCaseInsensitiveContains("token") && !$0.key.localizedCaseInsensitiveContains("secret") }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }

    private static func resolveID(from values: [String: AnyJSONValue]) -> String {
        for key in ["id", "ID", "name", "Name", "serviceId", "nodeId", "taskId", "repositoryUrl", "url"] {
            if let value = values[key]?.displayString, !value.isEmpty { return value }
        }
        if let data = try? JSONEncoder().encode(values),
           let text = String(data: data, encoding: .utf8) {
            return String(text.hashValue)
        }
        return UUID().uuidString
    }
}

nonisolated struct DynamicListEnvelope: Decodable, Sendable {
    let items: [DynamicResource]

    nonisolated init(from decoder: any Decoder) throws {
        if let array = try? [DynamicResource](from: decoder) {
            self.items = array
            return
        }
        let object = try [String: AnyJSONValue](from: decoder)
        for key in ["data", "items", "results", "services", "nodes", "tasks", "stacks", "configs", "secrets", "backups", "files", "repositories", "syncs", "jobs", "schedules"] {
            if let array = object[key]?.arrayValue {
                self.items = array.compactMap { value in
                    guard let object = value.objectValue else { return nil }
                    return DynamicResource(id: DynamicResource.resolveIDForEnvelope(from: object), values: object)
                }
                return
            }
        }
        self.items = [DynamicResource(id: "response", values: object)]
    }
}

extension DynamicResource {
    nonisolated fileprivate static func resolveIDForEnvelope(from values: [String: AnyJSONValue]) -> String {
        resolveID(from: values)
    }
}

nonisolated struct BackendFormField: Identifiable, Hashable, Sendable {
    enum FieldType: Hashable, Sendable {
        case text
        case secure
        case multiline
        case toggle
        case number
    }

    let id: String
    let label: String
    let type: FieldType
    let required: Bool
    let placeholder: String

    init(_ id: String, label: String, type: FieldType = .text, required: Bool = false, placeholder: String = "") {
        self.id = id
        self.label = label
        self.type = type
        self.required = required
        self.placeholder = placeholder
    }
}

nonisolated struct BackendListAction: Identifiable, Hashable, Sendable {
    enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case patch = "PATCH"
        case delete = "DELETE"
    }

    let id: String
    let title: String
    let systemImage: String
    let method: Method
    let pathSuffix: String
    let destructive: Bool
    let requiresSelection: Bool

    init(id: String, title: String, systemImage: String, method: Method, pathSuffix: String, destructive: Bool = false, requiresSelection: Bool = true) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.method = method
        self.pathSuffix = pathSuffix
        self.destructive = destructive
        self.requiresSelection = requiresSelection
    }
}
