import Foundation
import Arcane

enum ListSortOrder: String, CaseIterable, Identifiable {
    case ascending
    case descending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ascending: return "A-Z"
        case .descending: return "Z-A"
        }
    }

    var systemImage: String {
        switch self {
        case .ascending: return "arrow.up"
        case .descending: return "arrow.down"
        }
    }

    func areInIncreasingOrder(_ lhs: String, _ rhs: String) -> Bool {
        switch self {
        case .ascending:
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        case .descending:
            return lhs.localizedStandardCompare(rhs) == .orderedDescending
        }
    }
}

// MARK: - App compatibility names backed by libarcane-swift exports

typealias ImageInfo = ImageSummary
typealias ContainerInfo = ContainerSummary
typealias ServerEnvironment = Arcane.Environment
typealias Project = ProjectDetails
typealias VolumeInfo = Volume
typealias NetworkInfo = NetworkSummary
typealias ImageDetails = ImageDetailSummary
typealias ImageConfig = Components.Schemas.DetailSummaryConfigStruct
typealias ArcaneUser = User
typealias CreateUserRequest = CreateUser
typealias UpdateUserRequest = UpdateUser
typealias APIKey = ApiKey
typealias CreateAPIKeyRequest = CreateApiKey
typealias APIKeyCreated = ApiKeyCreatedDto
typealias CreateContainerRegistryRequest = Components.Schemas.CreateContainerRegistryRequest
typealias UpdateContainerRegistryRequest = Components.Schemas.UpdateContainerRegistryRequest
typealias TemplateRegistry = Components.Schemas.TemplateTemplateRegistry
typealias CreateTemplateRegistryRequest = Components.Schemas.TemplateCreateRegistryRequest
typealias UpdateTemplateRegistryRequest = Components.Schemas.TemplateUpdateRegistryRequest
typealias ComposeTemplate = Components.Schemas.TemplateTemplate
typealias ComposeTemplateContent = Components.Schemas.TemplateTemplateContent
typealias AnyCodable = JSONValue

struct DataResponse<T: Codable & Sendable>: Codable, Sendable {
    var data: T?
    var message: String?
    var success: Bool?

    enum CodingKeys: String, CodingKey {
        case data, message, success
    }

    init(data: T? = nil, message: String? = nil, success: Bool? = nil) {
        self.data = data
        self.message = message
        self.success = success
    }

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decodeIfPresent(T.self, forKey: .data)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        success = try container.decodeIfPresent(Bool.self, forKey: .success)
    }

    nonisolated func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(data, forKey: .data)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encodeIfPresent(success, forKey: .success)
    }
}

// MARK: - Display helpers

extension ImageInfo: Identifiable {
    var displayName: String {
        if let tag = repoTags?.first(where: { $0 != "<none>:<none>" }) { return tag }
        if !repo.isEmpty { return tag.isEmpty ? repo : "\(repo):\(tag)" }
        return String(id.prefix(12))
    }
}

extension ContainerInfo: Identifiable {
    var iconUrl: String? { labels.additionalProperties["com.getarcaneapp.icon"] }

    var displayName: String {
        let first = names?.first?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        return first.isEmpty ? String(id.prefix(12)) : first
    }

    var isRunning: Bool { state.lowercased() == "running" }
}

extension ContainerConfig {
    var image: String? { nil }
    var labels: [String: String]? { nil }
}

extension ContainerHostConfig {
    var binds: [String]? { nil }
}

extension ImageConfig {
    var entrypoint: [String]? { nil }
    var user: String? { nil }
    var labels: [String: String]? { nil }
}

extension ServerEnvironment: Identifiable {
    var url: String? { apiUrl }
    var agentVersion: String? { nil }
    var isOnline: Bool? { status.lowercased() == "online" || status.lowercased() == "up" || connected == true }
}

extension Project: Identifiable {
    var displayName: String { name }
    var composeVersion: String? { nil }

    var statusColor: String {
        switch status.lowercased() {
        case "running": return "green"
        case "stopped", "exited": return "red"
        case "partial", "partially running": return "orange"
        default: return "gray"
        }
    }
}

extension VolumeInfo: Identifiable {
    var labelsDictionary: [String: String] { labels.additionalProperties }
    var optionsDictionary: [String: String] { options.additionalProperties }
}

extension NetworkInfo: Identifiable {
    var isInternal: Bool { false }
    var containerCount: Int { 0 }
    var attachable: Bool? { nil }
    var ipam: NetworkIPAM? { nil }
    var containers: [String: NetworkContainer]? { nil }
    var labelsDictionary: [String: String] { labels.additionalProperties }
    var optionsDictionary: [String: String] { options.additionalProperties }
}

struct NetworkContainer: Codable, Hashable, Sendable {
    var name: String?
    var endpointID: String?
    var macAddress: String?
    var iPv4Address: String?
    var iPv6Address: String?
}

extension ArcaneUser: Identifiable {
    var isAdmin: Bool { roles?.contains("admin") ?? false }
    var displayUsername: String { username }
    var lastLogin: String? { nil }
}

extension APIKey: Identifiable {
    var isProtected: Bool? { isStatic }
    var permissions: [String]? { nil }
}

extension ContainerRegistry: Identifiable {
    var name: String? { url }
}

extension TemplateRegistry: Identifiable {}

extension ComposeTemplate: Identifiable {
    var iconUrl: String? { metadata?.iconUrl }
}

extension JSONValue {
    init(_ value: String) { self = .string(value) }
    init(_ value: Bool) { self = .bool(value) }
    init(_ value: Int) { self = .number(Double(value)) }
    init(_ value: Int64) { self = .number(Double(value)) }
    init(_ value: Double) { self = .number(value) }
    init(_ value: [String: JSONValue]) { self = .object(value) }
    init(_ value: [JSONValue]) { self = .array(value) }
}

extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

extension Int {
    var byteString: String { Int64(self).byteString }
}
