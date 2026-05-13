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
//
// Display models (`Project`, `ContainerInfo`, `ImageInfo`, `ImageDetails`,
// `NetworkInfo`, `ServerEnvironment`, `ArcaneUser`, `APIKey`,
// `ContainerRegistry`, `TemplateRegistry`, `ComposeTemplate`,
// `ComposeTemplateContent`, `WebhookSummary`) live in `ResilientModels.swift`
// as hand-written, schema-tolerant structs that decode every field with
// `decodeIfPresent`. Only request/sub-type aliases that flow *into* the SDK
// stay here.

typealias CreateUserRequest = CreateUser
typealias UpdateUserRequest = UpdateUser
typealias CreateAPIKeyRequest = CreateApiKey
typealias APIKeyCreated = ApiKeyCreatedDto
typealias CreateContainerRegistryRequest = Components.Schemas.CreateContainerRegistryRequest
typealias UpdateContainerRegistryRequest = Components.Schemas.UpdateContainerRegistryRequest
typealias CreateTemplateRegistryRequest = Components.Schemas.TemplateCreateRegistryRequest
typealias UpdateTemplateRegistryRequest = Components.Schemas.TemplateUpdateRegistryRequest
typealias AnyCodable = JSONValue

// MARK: - Notification type aliases
typealias NotificationSettingsResponse = NotificationResponse
typealias NotificationSettingsUpdate = NotificationUpdate

// MARK: - Webhook type aliases
typealias WebhookCreateModel = WebhookCreateInput
typealias WebhookCreatedModel = WebhookCreated
typealias WebhookSummaryModel = WebhookSummary
typealias WebhookUpdateModel = WebhookUpdateInput

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

// `ImageInfo`, `ContainerInfo`, `ServerEnvironment`, `Project` and their
// computed properties (displayName, isRunning, statusColor, isOnline, etc.)
// now live as concrete types in `ResilientModels.swift`.

extension ContainerConfig {
    var image: String? { nil }
    var labels: [String: String]? { nil }
}

extension ContainerHostConfig {
    var binds: [String]? { nil }
}

nonisolated struct VolumeSizeInfo: Codable, Sendable {
    let name: String
    let size: Int64
    let refCount: Int64?
}

// Tolerant volume model — the OpenAPI-generated `Volume` type marks `labels`
// and `options` as required, but the Docker daemon sends them as `null` when
// empty, which the SDK can't decode. We fetch raw bytes on the volumes endpoint
// and decode this struct instead.
nonisolated struct VolumeInfo: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let driver: String
    let mountpoint: String
    let scope: String
    let createdAt: String
    let inUse: Bool?
    let size: Int64?
    let labels: [String: String]?
    let options: [String: String]?
    let containers: [String]?

    var labelsDictionary: [String: String] { labels ?? [:] }
    var optionsDictionary: [String: String] { options ?? [:] }
}

// Tolerant project-files model — the OpenAPI-generated `ProjectDetails` type
// requires Int64 fields (mem_limit, cpu_quota, shm_size, stop_grace_period,
// etc.) on parsed compose services, but the backend can pass those through
// as strings ("256m", "30s") since compose accepts either form. This struct
// only decodes the fields the compose-file editor actually needs.
nonisolated struct ProjectFiles: Codable, Sendable {
    let name: String
    let composeContent: String?
    let envContent: String?
}

extension NotificationResponse: @retroactive Identifiable {}

extension SettingDto: @retroactive Identifiable {
    public var id: String { key }
}

extension PublicSetting: @retroactive Identifiable {
    public var id: String { key }
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

// MARK: - Error formatting

func friendlyErrorMessage(_ error: Error) -> String {
    if let arcane = error as? ArcaneError {
        switch arcane {
        case .unauthorized: return "Not signed in"
        case .forbidden: return "You don't have permission to do that"
        case .notFound: return "Not found"
        case .conflict(let message): return message ?? "Conflict"
        case .validation(let fields):
            let firstField = fields.sorted(by: { $0.key < $1.key }).first
            if let (name, messages) = firstField, let first = messages.first {
                return "\(name): \(first)"
            }
            return "Validation failed"
        case .rateLimited(let retryAfter):
            if let secs = retryAfter {
                return "Rate limited — retry in \(Int(secs))s"
            }
            return "Rate limited — please wait"
        case .server(_, let message): return message.isEmpty ? "Server error" : message
        case .transport(let message):
            if message.lowercased().contains("cancel") { return "Cancelled" }
            return "Connection error: \(message)"
        case .decoding(let message): return "Response error: \(message)"
        case .unknown(let code, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Error \(code)" : "Error \(code): \(trimmed.prefix(200))"
        }
    }
    if (error as NSError).domain == NSURLErrorDomain,
       let urlError = error as? URLError,
       urlError.code == .cancelled {
        return "Cancelled"
    }
    return error.localizedDescription
}

// MARK: - Image pull / prune

nonisolated struct PullImageRequest: Encodable, Sendable {
    let imageName: String
    let tag: String?
}

nonisolated struct ProjectListPage: Codable, Sendable {
    let success: Bool
    let data: [Project]
    let pagination: PaginationResponse
}

nonisolated struct ImageListPage: Codable, Sendable {
    let success: Bool
    let data: [ImageInfo]
    let pagination: PaginationResponse
}

nonisolated struct NetworkListPage: Codable, Sendable {
    let success: Bool
    let data: [NetworkInfo]
    let pagination: PaginationResponse
}

nonisolated struct VolumeListPage: Codable, Sendable {
    let success: Bool
    let data: [VolumeInfo]
    let pagination: PaginationResponse
}

nonisolated struct DestroyProjectRequest: Encodable, Sendable {
    let removeFiles: Bool
    let removeVolumes: Bool
}

nonisolated struct PullProgressEvent: Decodable, Sendable {
    let type: String?
    let phase: String?
    let status: String?
    let id: String?
    let progressDetail: ProgressDetail?
    let error: String?

    nonisolated struct ProgressDetail: Decodable, Sendable {
        let current: Int64?
        let total: Int64?
    }

    var isLayerEvent: Bool { id?.isEmpty == false }
}

nonisolated struct ImagePruneRequest: Encodable, Sendable {
    let mode: String?
    let until: String?
    let dangling: Bool?
    let filters: [String: [String]]?
}

nonisolated struct ImagePruneReport: Codable, Sendable {
    let imagesDeleted: [String]?
    let spaceReclaimed: Int64?
}

// MARK: - System prune (consolidated)

nonisolated struct PruneAllRequest: Encodable, Sendable {
    let containers: PruneContainersOptions?
    let images: PruneImagesOptions?
    let volumes: PruneVolumesOptions?
    let networks: PruneNetworksOptions?
    let buildCache: PruneBuildCacheOptions?
}

nonisolated struct PruneContainersOptions: Encodable, Sendable {
    let mode: String      // "none" | "stopped" | "olderThan"
    let until: String?
}

nonisolated struct PruneImagesOptions: Encodable, Sendable {
    let mode: String      // "none" | "dangling" | "all" | "olderThan"
    let until: String?
}

nonisolated struct PruneVolumesOptions: Encodable, Sendable {
    let mode: String      // "none" | "anonymous" | "all"
}

nonisolated struct PruneNetworksOptions: Encodable, Sendable {
    let mode: String      // "none" | "unused" | "olderThan"
    let until: String?
}

nonisolated struct PruneBuildCacheOptions: Encodable, Sendable {
    let mode: String      // "none" | "unused" | "all" | "olderThan"
    let until: String?
}

nonisolated struct PruneAllResult: Codable, Sendable {
    let containersPruned: [String]?
    let imagesDeleted: [String]?
    let volumesDeleted: [String]?
    let networksDeleted: [String]?
    let spaceReclaimed: Int64?
    let containerSpaceReclaimed: Int64?
    let imageSpaceReclaimed: Int64?
    let volumeSpaceReclaimed: Int64?
    let buildCacheSpaceReclaimed: Int64?
    let success: Bool?
    let errors: [String]?
}

// MARK: - Image update checks

nonisolated struct ImageUpdateResponse: Codable, Sendable {
    let hasUpdate: Bool
    let updateType: String?
    let currentVersion: String?
    let latestVersion: String?
    let currentDigest: String?
    let latestDigest: String?
    let checkTime: String?
    let responseTimeMs: Int?
    let error: String?
    let authMethod: String?
    let authUsername: String?
    let authRegistry: String?
    let usedCredential: Bool?
}

nonisolated struct ImageUpdateSummary: Codable, Sendable {
    let totalImages: Int
    let imagesWithUpdates: Int
    let digestUpdates: Int
    let errorsCount: Int
}

nonisolated struct BatchImageUpdateRequest: Encodable, Sendable {
    let imageRefs: [String]
}

typealias BatchImageUpdateResponse = [String: ImageUpdateResponse]

// MARK: - Vulnerabilities

nonisolated enum VulnerabilitySeverity: String, CaseIterable, Codable, Sendable, Identifiable {
    case critical = "CRITICAL"
    case high = "HIGH"
    case medium = "MEDIUM"
    case low = "LOW"
    case unknown = "UNKNOWN"

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .critical: return "Critical"
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        case .unknown: return "Unknown"
        }
    }
}

nonisolated struct VulnerabilityRecord: Codable, Sendable, Identifiable {
    let vulnerabilityId: String
    let pkgName: String
    let installedVersion: String?
    let fixedVersion: String?
    let severity: String
    let title: String?
    let description: String?
    let references: [String]?
    let cvss: CVSSInfo?
    let publishedDate: String?
    let lastModifiedDate: String?

    var id: String { "\(vulnerabilityId)|\(pkgName)|\(installedVersion ?? "")" }
    var severityValue: VulnerabilitySeverity {
        VulnerabilitySeverity(rawValue: severity.uppercased()) ?? .unknown
    }
}

nonisolated struct VulnerabilityWithImage: Codable, Sendable, Identifiable {
    let vulnerabilityId: String
    let pkgName: String
    let installedVersion: String?
    let fixedVersion: String?
    let severity: String
    let title: String?
    let description: String?
    let references: [String]?
    let cvss: CVSSInfo?
    let publishedDate: String?
    let lastModifiedDate: String?
    let imageId: String
    let imageName: String

    var id: String { "\(imageId)|\(vulnerabilityId)|\(pkgName)" }
    var severityValue: VulnerabilitySeverity {
        VulnerabilitySeverity(rawValue: severity.uppercased()) ?? .unknown
    }
}

nonisolated struct CVSSInfo: Codable, Sendable {
    let v2Score: Double?
    let v3Score: Double?
    let v2Vector: String?
    let v3Vector: String?

    var preferredScore: Double? { v3Score ?? v2Score }
}

nonisolated struct SeveritySummary: Codable, Sendable {
    let critical: Int
    let high: Int
    let medium: Int
    let low: Int
    let unknown: Int
    let total: Int
}

nonisolated struct ScanSummary: Codable, Sendable {
    let imageId: String
    let scanTime: String?
    let status: String
    let scanPhase: String?
    let summary: SeveritySummary?
    let error: String?
}

nonisolated struct ScanResult: Codable, Sendable {
    let imageId: String
    let imageName: String
    let scanTime: String?
    let status: String
    let scanPhase: String?
    let summary: SeveritySummary?
    let vulnerabilities: [VulnerabilityRecord]?
    let error: String?
    let duration: Int64?
    let scannerVersion: String?
}

nonisolated struct ScannerStatus: Codable, Sendable {
    let available: Bool
    let version: String?
}

nonisolated struct ScanSummariesRequest: Encodable, Sendable {
    let imageIds: [String]
}

nonisolated struct ScanSummariesResponse: Codable, Sendable {
    let summaries: [String: ScanSummary]
}

nonisolated struct EnvironmentVulnerabilitySummary: Codable, Sendable {
    let totalImages: Int
    let scannedImages: Int
    let summary: SeveritySummary?
}

nonisolated struct IgnoreVulnerabilityRequest: Encodable, Sendable {
    let imageId: String
    let vulnerabilityId: String
    let pkgName: String
    let installedVersion: String?
    let reason: String?
}

nonisolated struct IgnoredVulnerability: Codable, Sendable, Identifiable {
    let id: String
    let environmentId: String?
    let imageId: String
    let vulnerabilityId: String
    let pkgName: String
    let installedVersion: String
    let reason: String?
    let createdBy: String?
    let createdAt: String?
}
