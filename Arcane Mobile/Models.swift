import Foundation
import SwiftUI
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

enum ResourceUpdateFilter: String, CaseIterable, Identifiable {
    case all
    case hasUpdates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .hasUpdates: return "Has Updates"
        }
    }

    func matches(hasUpdate: Bool) -> Bool {
        switch self {
        case .all: return true
        case .hasUpdates: return hasUpdate
        }
    }
}

// MARK: - App compatibility names backed by libarcane-swift exports
//
// Display models (`Project`, `ContainerSummary`, `ImageSummary`, `ImageDetailSummary`,
// `NetworkSummary`, `Environment`, `User`, `APIKey`,
// `ContainerRegistry`, `TemplateRegistry`, `Template`,
// `TemplateContent`, `Webhook`) live in `ResilientModels.swift`
// as hand-written, schema-tolerant structs that decode every field with
// `decodeIfPresent`. Only request/sub-type aliases that flow *into* the SDK
// stay here.

typealias CreateUserRequest = CreateUser
typealias UpdateUserRequest = UpdateUser
typealias CreateAPIKeyRequest = CreateAPIKey
typealias CreateContainerRegistryRequest = CreateContainerRegistry
typealias UpdateContainerRegistryRequest = UpdateContainerRegistry
typealias CreateTemplateRegistryRequest = CreateTemplateRegistry
typealias UpdateTemplateRegistryRequest = UpdateTemplateRegistry
typealias AnyCodable = JSONValue

// MARK: - Notification type aliases
typealias NotificationSettingsResponse = NotificationSettings
typealias NotificationSettingsUpdate = UpdateNotificationSettings

// MARK: - Webhook type aliases
typealias WebhookCreateModel = CreateWebhook
typealias WebhookCreatedModel = WebhookCreated
typealias WebhookSummaryModel = Webhook
typealias WebhookUpdateModel = UpdateWebhook

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

// `ImageSummary`, `ContainerSummary`, `Environment`, `Project` and their
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

/// Connected server's build metadata from `/app-version`. Decoded locally
/// (rather than via the SDK's `VersionInfo`) so we also surface `nodeVersion`
/// and `svelteKitVersion`, which the SDK model doesn't expose. Every field is
/// optional so it decodes cleanly against both v1 and v2 backends — missing
/// keys simply yield `nil` and their rows are hidden.
nonisolated struct ServerVersionInfo: Codable, Sendable {
    var displayVersion: String?
    var currentVersion: String?
    var currentTag: String?
    var currentDigest: String?
    var revision: String?
    var shortRevision: String?
    var goVersion: String?
    var nodeVersion: String?
    var svelteKitVersion: String?
    var enabledFeatures: [String]?
    var buildTime: String?
    var updateAvailable: Bool?
    var newestVersion: String?
    var releaseUrl: String?
}

// `NotificationSettings: Identifiable` is now stated in the SDK itself.

extension ContainerRegistry {
    /// Best-effort display name. The SDK type carries a `description` field;
    /// fall back to the URL host when description is empty.
    var name: String? {
        if let desc = description, !desc.isEmpty { return desc }
        return URL(string: url)?.host ?? url
    }
}

extension Template {
    /// Convenience accessor that surfaces the icon URL from metadata, since
    /// the SDK keeps it inside the `metadata` blob.
    var iconUrl: String? { metadata?.iconUrl }
}

extension APIKey {
    /// Compat alias for the renamed `isStatic` field — these flags conveyed
    /// the same "can't be deleted via UI" semantic.
    var isProtected: Bool { isStatic }
}

extension User {
    /// Prefer the human-friendly `displayName` when set, fall back to `username`.
    var displayUsername: String {
        if let name = displayName, !name.isEmpty { return name }
        return username
    }
}

extension ContainerSummary {
    var displayName: String {
        let first = names.first?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        return first.isEmpty ? String(id.prefix(12)) : first
    }
    var isRunning: Bool { state.lowercased() == "running" }
    var iconUrl: String? { ThemedIconURL.firstUsableURL(legacyIconUrl) }
    var legacyIconUrl: String? {
        labels["com.getarcaneapp.arcane.icon"] ?? labels["arcane.icon"]
    }
    func themedIconUrl(for colorScheme: ColorScheme) -> String? {
        ThemedIconURL.select(
            iconLightUrl: iconLightUrl,
            iconDarkUrl: iconDarkUrl,
            fallback: legacyIconUrl,
            colorScheme: colorScheme
        )
    }
    var hasAvailableUpdate: Bool { updateInfo?.hasUpdate == true }
}

extension ContainerDetails {
    var legacyIconUrl: String? {
        labels?["com.getarcaneapp.arcane.icon"] ?? labels?["arcane.icon"]
    }
    func themedIconUrl(for colorScheme: ColorScheme) -> String? {
        ThemedIconURL.select(
            iconLightUrl: iconLightUrl,
            iconDarkUrl: iconDarkUrl,
            fallback: legacyIconUrl,
            colorScheme: colorScheme
        )
    }
}

extension ImageSummary {
    var displayName: String {
        if let tag = repoTags.first(where: { $0 != "<none>:<none>" }) { return tag }
        return String(id.prefix(12))
    }
}

extension ProjectDetails {
    var displayName: String { name }
    var composeVersion: String? { nil }
    func themedIconUrl(for colorScheme: ColorScheme) -> String? {
        ThemedIconURL.select(
            iconLightUrl: iconLightUrl,
            iconDarkUrl: iconDarkUrl,
            fallback: iconUrl,
            colorScheme: colorScheme
        )
    }
    var hasAvailableUpdate: Bool { updateInfo?.hasUpdate == true }
    var statusColor: String {
        switch status.lowercased() {
        case "running": return "green"
        case "stopped", "exited": return "red"
        case "partial", "partially running": return "orange"
        default: return "gray"
        }
    }
}

extension RuntimeService {
    func themedIconUrl(for colorScheme: ColorScheme) -> String? {
        ThemedIconURL.select(
            iconLightUrl: iconLightUrl,
            iconDarkUrl: iconDarkUrl,
            fallback: iconUrl,
            colorScheme: colorScheme
        )
    }
}

private enum ThemedIconURL {
    static func select(
        iconLightUrl: String?,
        iconDarkUrl: String?,
        fallback: String?,
        colorScheme: ColorScheme
    ) -> String? {
        switch colorScheme {
        case .light:
            return firstUsableURL(iconDarkUrl, iconLightUrl, fallback)
        case .dark:
            return firstUsableURL(iconLightUrl, iconDarkUrl, fallback)
        @unknown default:
            return firstUsableURL(iconLightUrl, iconDarkUrl, fallback)
        }
    }

    static func firstUsableURL(_ values: String?...) -> String? {
        for value in values {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty,
                  isDirectURL(trimmed) else {
                continue
            }
            return trimmed
        }
        return nil
    }

    private static func isDirectURL(_ value: String) -> Bool {
        if value.hasPrefix("/") { return true }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }
}

extension Arcane.Environment {
    var displayName: String { name?.isEmpty == false ? (name ?? "") : "Environment \(id)" }
    var isOnline: Bool? {
        let lower = status.lowercased()
        return lower == "online" || lower == "up"
    }
    /// Backwards-compat alias for the renamed `apiUrl` property.
    var url: String { apiUrl }
}

typealias SettingsUpdate = UpdateSettings
typealias UpgradeCheckResultData = UpgradeCheckResult
typealias Project = ProjectDetails

// MARK: - NetworkSummary compatibility
//
// The SDK's `NetworkSummary` no longer carries `isInternal` or
// `containerCount` — those come from the full inspect payload. The list views
// previously read them; expose stub defaults so the UI compiles. They'll just
// render the "not internal" / "no containers" path until we're ready to
// upgrade those views to read `NetworkInspect`.
extension NetworkSummary {
    /// Always false for now — the summary endpoint doesn't carry this flag.
    var isInternal: Bool { false }
    /// Always zero for now — the summary endpoint doesn't carry connection counts.
    var containerCount: Int { 0 }
}

// MARK: - DockerInfo convenience accessors
//
// The SDK exposes the embedded Docker `system.Info` blob as a raw map under
// `info`. The dashboard views still want strongly-typed properties for the
// most commonly-rendered fields. Surface them as computed properties.
extension DockerInfo {
    // Counts
    var containers: Int64 { info?["Containers"]?.int64Value ?? 0 }
    var containersRunning: Int64 { info?["ContainersRunning"]?.int64Value ?? 0 }
    var containersPaused: Int64 { info?["ContainersPaused"]?.int64Value ?? 0 }
    var containersStopped: Int64 { info?["ContainersStopped"]?.int64Value ?? 0 }
    var images: Int64 { info?["Images"]?.int64Value ?? 0 }

    // Identity / host
    var id: String { info?["ID"]?.stringValue ?? "" }
    var kernelVersion: String { info?["KernelVersion"]?.stringValue ?? "" }
    var architecture: String { info?["Architecture"]?.stringValue ?? "" }
    var osType: String { info?["OSType"]?.stringValue ?? "" }

    // Runtime
    var driver: String { info?["Driver"]?.stringValue ?? "" }
    var loggingDriver: String { info?["LoggingDriver"]?.stringValue ?? "" }
    var cgroupDriver: String { info?["CgroupDriver"]?.stringValue ?? "" }
    var cgroupVersion: String? { info?["CgroupVersion"]?.stringValue }
    var defaultRuntime: String { info?["DefaultRuntime"]?.stringValue ?? "" }
    var dockerRootDir: String { info?["DockerRootDir"]?.stringValue ?? "" }

    // Features
    var liveRestoreEnabled: Bool { info?["LiveRestoreEnabled"]?.boolValue ?? false }
    var experimentalBuild: Bool { info?["ExperimentalBuild"]?.boolValue ?? false }
    var debug: Bool { info?["Debug"]?.boolValue ?? false }
    var iPv4Forwarding: Bool { info?["IPv4Forwarding"]?.boolValue ?? false }
    var memoryLimit: Bool { info?["MemoryLimit"]?.boolValue ?? false }
    var swapLimit: Bool { info?["SwapLimit"]?.boolValue ?? false }

    var warnings: [String]? {
        guard case let .array(values) = info?["Warnings"] else { return nil }
        return values.compactMap { $0.stringValue }
    }

    /// Mirrors Docker's `Info.Runtimes` map. Surfaces a `keys` view that the
    /// dashboard uses to display the available runtime names.
    var runtimes: RuntimesView {
        if case let .object(map) = info?["Runtimes"] {
            return RuntimesView(additionalProperties: map)
        }
        return RuntimesView(additionalProperties: [:])
    }

    struct RuntimesView {
        let additionalProperties: [String: JSONValue]
    }
}

// MARK: - Webhook payload helpers
//
// The SDK models `CreateWebhook.targetType` / `actionType` as raw strings to
// match the wire format. The iOS views express them as typed enums, so we
// expose those as nested types here. They're string-backed; convert to/from
// raw strings at the SDK boundary.
extension CreateWebhook {
    enum TargetTypePayload: String, CaseIterable, Sendable {
        case container
        case project
        case updater
        case gitops
    }

    enum ActionTypePayload: String, CaseIterable, Sendable {
        case update, start, stop, restart, redeploy, up, down, run, sync
    }

    /// View-facing initializer that takes the typed enums and stores their
    /// raw string values, which is what the SDK + backend expect.
    init(name: String,
         targetType: TargetTypePayload,
         actionType: ActionTypePayload,
         targetId: String) {
        self.init(
            name: name,
            targetType: targetType.rawValue,
            actionType: actionType.rawValue,
            targetId: targetId
        )
    }

    init(actionType: ActionTypePayload,
         name: String,
         targetId: String,
         targetType: TargetTypePayload) {
        self.init(
            name: name,
            targetType: targetType.rawValue,
            actionType: actionType.rawValue,
            targetId: targetId
        )
    }
}

// MARK: - SystemStats compatibility
//
// Views were written against an iOS-side `SystemStatsFrame` with explicit
// `*Bytes` and `*Percent` accessors. The SDK's canonical `SystemStats` keeps
// the wire field names (`memoryUsage`, `memoryTotal`, `diskUsage`, etc.) — we
// bridge them here so existing call sites keep working.
typealias SystemStatsFrame = SystemStats

extension SystemStats {
    /// CPU usage as a percentage in the 0–100 range.
    var cpuPercent: Double { cpuUsage }
    /// Memory used in bytes.
    var memoryUsageBytes: Int64 { Int64(memoryUsage) }
    /// Total memory in bytes.
    var memoryTotalBytes: Int64 { Int64(memoryTotal) }
    /// Disk used in bytes, if reported.
    var diskUsageBytes: Int64? { diskUsage.map(Int64.init) }
    /// Total disk in bytes, if reported.
    var diskTotalBytes: Int64? { diskTotal.map(Int64.init) }
    /// Memory used as a percentage, derived from used/total bytes.
    var memoryPercent: Double? {
        guard memoryTotal > 0 else { return nil }
        return (Double(memoryUsage) / Double(memoryTotal)) * 100.0
    }
}

// MARK: - Updater convenience accessors
//
// libarcane-swift exposes `oldImageVersions` / `newImageVersions` as
// `[String: JSONValue]?` to tolerate the server's varying value shapes.
// These computed accessors extract the string projection.

extension AutoUpdateRecord {
    var oldImageVersionsMap: [String: String] { Self.flatten(oldImageVersions) }
    var newImageVersionsMap: [String: String] { Self.flatten(newImageVersions) }

    private static func flatten(_ values: [String: JSONValue]?) -> [String: String] {
        guard let values else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in values {
            if case let .string(text) = value { out[key] = text }
        }
        return out
    }
}

extension Event {
    /// Flattens the JSON metadata payload to `[String: String]`. Non-string
    /// values are rendered as their JSON representation so the metadata is
    /// still inspectable.
    var metadataMap: [String: String] {
        guard let metadata else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in metadata {
            switch value {
            case let .string(s): out[key] = s
            case let .number(n):
                if n.rounded() == n { out[key] = "\(Int64(n))" }
                else { out[key] = "\(n)" }
            case let .bool(b): out[key] = b ? "true" : "false"
            case .null: out[key] = "null"
            case .array, .object:
                if let data = try? JSONEncoder().encode(value),
                   let text = String(data: data, encoding: .utf8) {
                    out[key] = text
                }
            }
        }
        return out
    }
}

// `SettingDto` and `PublicSetting` already conform to `Identifiable` in the SDK.

extension JSONValue {
    init(_ value: String) { self = .string(value) }
    init(_ value: Bool) { self = .bool(value) }
    init(_ value: Int) { self = .number(Double(value)) }
    init(_ value: Int64) { self = .number(Double(value)) }
    init(_ value: Double) { self = .number(value) }
    init(_ value: [String: JSONValue]) { self = .object(value) }
    init(_ value: [JSONValue]) { self = .array(value) }

    var objectValue: [String: JSONValue]? {
        if case let .object(map) = self { return map }
        return nil
    }
    var arrayValue: [JSONValue]? {
        if case let .array(values) = self { return values }
        return nil
    }
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
        case .conflict(let message): return cleanErrorText(message) ?? "Conflict"
        case .validation(let fields):
            let sorted = fields.sorted(by: { $0.key < $1.key })
            guard let (firstName, messages) = sorted.first, let firstMessage = messages.first else {
                return "Validation failed"
            }
            let displayName = humanizeFieldName(firstName)
            if sorted.count <= 1 {
                return "\(displayName): \(firstMessage)"
            }
            return "\(sorted.count) fields need attention — \(displayName): \(firstMessage)"
        case .rateLimited(let retryAfter):
            if let secs = retryAfter {
                return "Rate limited — retry in \(Int(secs))s"
            }
            return "Rate limited — please wait"
        case .server(_, let message):
            return cleanErrorText(message) ?? "Server error"
        case .transport(let message):
            let lower = message.lowercased()
            if lower.contains("cancel") { return "Cancelled" }
            if lower.contains("could not connect to the server") || lower.contains("connection refused") {
                return "Can't reach the server — check the address and that it's running."
            }
            if lower.contains("hostname could not be found")
                || lower.contains("server with the specified hostname could not be found") {
                return "Server not found — check the address."
            }
            if lower.contains("timed out") {
                return "Connection timed out — check the address and your network."
            }
            if lower.contains("secure connection") || lower.contains("ssl") {
                return "Secure connection failed — for a local server use http://, or check the server's certificate."
            }
            if lower.contains("app transport security") {
                return "Blocked an insecure connection — check the server URL."
            }
            return "Connection error: \(message)"
        case .decoding(let message): return "Response error: \(message)"
        case .unknown(let code, _):
            return "Something went wrong (\(code))"
        }
    }
    if (error as NSError).domain == NSURLErrorDomain,
       let urlError = error as? URLError,
       urlError.code == .cancelled {
        return "Cancelled"
    }
    return error.localizedDescription
}

private func cleanErrorText(_ message: String?) -> String? {
    guard let message else { return nil }
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return nil }
    return trimmed
}

private func humanizeFieldName(_ name: String) -> String {
    let last = name.split(separator: ".").last.map(String.init) ?? name
    guard let first = last.first else { return last }
    return first.uppercased() + last.dropFirst()
}

// MARK: - Image pull

nonisolated struct PullImageRequest: Encodable, Sendable {
    let imageName: String
    let tag: String?
}

// Use `PaginatedResponse<T>` from libarcane-swift via `client.<service>.list(...)`.

nonisolated struct DestroyProjectRequest: Encodable, Sendable {
    let removeFiles: Bool
    let removeVolumes: Bool
}

// `PullProgressEvent` is provided by the SDK. We extend it locally with the
// `isLayerEvent` helper the views previously relied on.
extension PullProgressEvent {
    var isLayerEvent: Bool { id?.isEmpty == false }
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
