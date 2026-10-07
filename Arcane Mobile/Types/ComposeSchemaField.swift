import Foundation

nonisolated struct ComposeSchemaField: Identifiable {
    let name: String
    let description: String
    let kinds: [ComposeNativeKind]
    let enumValues: [String]
    var id: String { name }
    /// Text retains Compose interpolation for numeric and boolean alternatives.
    var preferredKind: ComposeNativeKind { kinds.contains(.string) ? .string : (kinds.first ?? .string) }
}

/// Immutable JSON nodes allow schema lookup outside the main actor.
nonisolated indirect enum ComposeSchemaValue: Decodable, Sendable {
    case object([String: ComposeSchemaValue]), array([ComposeSchemaValue]), string(String)
    case number(Double), boolean(Bool), null

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let object = try? value.decode([String: ComposeSchemaValue].self) { self = .object(object) }
        else if let array = try? value.decode([ComposeSchemaValue].self) { self = .array(array) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let boolean = try? value.decode(Bool.self) { self = .boolean(boolean) }
        else { self = .number(try value.decode(Double.self)) }
    }

    var object: [String: ComposeSchemaValue] { if case .object(let value) = self { return value }; return [:] }
    var array: [ComposeSchemaValue] { if case .array(let value) = self { return value }; return [] }
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var literal: String? {
        switch self {
        case .string(let value): value
        case .boolean(let value): value ? "true" : "false"
        case .number(let value): value.rounded() == value ? String(format: "%.0f", value) : String(value)
        case .null: "null"
        default: nil
        }
    }
}

nonisolated final class ComposeSchemaResourceMarker: NSObject {}
