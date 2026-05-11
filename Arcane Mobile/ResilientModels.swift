import Foundation
import Arcane

// Hand-written, schema-tolerant replacements for the strict OpenAPI-generated
// SDK types we display in the UI. Every field is decoded with `decodeIfPresent`
// (or `try?`) and falls back to a sensible default when the backend omits it,
// so a single missing field on an older Arcane backend can no longer take down
// an entire screen. `id` is the only field that throws on absence — when an
// item lacks an id, `LenientArray` drops it from the list rather than letting
// duplicate-ID rows crash SwiftUI.

// MARK: - Project

nonisolated struct Project: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let status: String
    let path: String
    let createdAt: String
    let updatedAt: String
    let isArchived: Bool
    let runningCount: Int64
    let serviceCount: Int64
    let archivedAt: Date?
    let composeContent: String?
    let composeFileName: String?
    let dirName: String?
    let envContent: String?
    let gitOpsManagedBy: String?
    let gitRepositoryURL: String?
    let hasBuildDirective: Bool?
    let iconUrl: String?
    let lastSyncCommit: String?
    let redeployDisabled: Bool?
    let relativePath: String?
    let statusReason: String?
    let urls: [String]?

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

    enum CodingKeys: String, CodingKey {
        case id, name, status, path, createdAt, updatedAt, isArchived
        case runningCount, serviceCount, archivedAt, composeContent
        case composeFileName, dirName, envContent, gitOpsManagedBy
        case gitRepositoryURL, hasBuildDirective, iconUrl, lastSyncCommit
        case redeployDisabled, relativePath, statusReason, urls
    }

    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        self.status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? ""
        self.path = (try? c.decodeIfPresent(String.self, forKey: .path)) ?? ""
        self.createdAt = (try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? ""
        self.updatedAt = (try? c.decodeIfPresent(String.self, forKey: .updatedAt)) ?? ""
        self.isArchived = (try? c.decodeIfPresent(Bool.self, forKey: .isArchived)) ?? false
        self.runningCount = (try? c.decodeIfPresent(Int64.self, forKey: .runningCount)) ?? 0
        self.serviceCount = (try? c.decodeIfPresent(Int64.self, forKey: .serviceCount)) ?? 0
        self.archivedAt = try? c.decodeIfPresent(Date.self, forKey: .archivedAt)
        self.composeContent = try? c.decodeIfPresent(String.self, forKey: .composeContent)
        self.composeFileName = try? c.decodeIfPresent(String.self, forKey: .composeFileName)
        self.dirName = try? c.decodeIfPresent(String.self, forKey: .dirName)
        self.envContent = try? c.decodeIfPresent(String.self, forKey: .envContent)
        self.gitOpsManagedBy = try? c.decodeIfPresent(String.self, forKey: .gitOpsManagedBy)
        self.gitRepositoryURL = try? c.decodeIfPresent(String.self, forKey: .gitRepositoryURL)
        self.hasBuildDirective = try? c.decodeIfPresent(Bool.self, forKey: .hasBuildDirective)
        self.iconUrl = try? c.decodeIfPresent(String.self, forKey: .iconUrl)
        self.lastSyncCommit = try? c.decodeIfPresent(String.self, forKey: .lastSyncCommit)
        self.redeployDisabled = try? c.decodeIfPresent(Bool.self, forKey: .redeployDisabled)
        self.relativePath = try? c.decodeIfPresent(String.self, forKey: .relativePath)
        self.statusReason = try? c.decodeIfPresent(String.self, forKey: .statusReason)
        self.urls = try? c.decodeIfPresent([String].self, forKey: .urls)
    }
}

// MARK: - ContainerInfo

nonisolated struct ContainerInfo: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let image: String
    let state: String
    let status: String
    let names: [String]?
    let labels: [String: String]?
    let imageId: String?
    let command: String?
    let created: Int64?

    var displayName: String {
        let first = names?.first?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        return first.isEmpty ? String(id.prefix(12)) : first
    }

    var isRunning: Bool { state.lowercased() == "running" }
    var iconUrl: String? { labels?["com.getarcaneapp.arcane.icon"] }

    enum CodingKeys: String, CodingKey {
        case id, image, state, status, names, labels, imageId, command, created
    }

    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.image = (try? c.decodeIfPresent(String.self, forKey: .image)) ?? ""
        self.state = (try? c.decodeIfPresent(String.self, forKey: .state)) ?? ""
        self.status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? ""
        self.names = try? c.decodeIfPresent([String].self, forKey: .names)
        self.labels = try? c.decodeIfPresent([String: String].self, forKey: .labels)
        self.imageId = try? c.decodeIfPresent(String.self, forKey: .imageId)
        self.command = try? c.decodeIfPresent(String.self, forKey: .command)
        self.created = try? c.decodeIfPresent(Int64.self, forKey: .created)
    }
}

// MARK: - ImageInfo

nonisolated struct ImageInfo: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let repo: String
    let tag: String
    let inUse: Bool
    let size: Int64
    let virtualSize: Int64
    let created: Int64
    let repoTags: [String]?
    let repoDigests: [String]?

    var displayName: String {
        if let tag = repoTags?.first(where: { $0 != "<none>:<none>" }) { return tag }
        if !repo.isEmpty { return tag.isEmpty ? repo : "\(repo):\(tag)" }
        return String(id.prefix(12))
    }

    enum CodingKeys: String, CodingKey {
        case id, repo, tag, inUse, size, virtualSize, created, repoTags, repoDigests
    }

    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.repo = (try? c.decodeIfPresent(String.self, forKey: .repo)) ?? ""
        self.tag = (try? c.decodeIfPresent(String.self, forKey: .tag)) ?? ""
        self.inUse = (try? c.decodeIfPresent(Bool.self, forKey: .inUse)) ?? false
        self.size = (try? c.decodeIfPresent(Int64.self, forKey: .size)) ?? 0
        self.virtualSize = (try? c.decodeIfPresent(Int64.self, forKey: .virtualSize)) ?? 0
        self.created = (try? c.decodeIfPresent(Int64.self, forKey: .created)) ?? 0
        self.repoTags = try? c.decodeIfPresent([String].self, forKey: .repoTags)
        self.repoDigests = try? c.decodeIfPresent([String].self, forKey: .repoDigests)
    }
}

// MARK: - ImageDetails

nonisolated struct ImageDetails: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let created: String
    let architecture: String
    let os: String
    let size: Int64
    let author: String
    let comment: String
    let repoTags: [String]?
    let repoDigests: [String]?
    let config: ImageConfig?

    enum CodingKeys: String, CodingKey {
        case id, created, architecture, os, size, author, comment
        case repoTags, repoDigests, config
    }

    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.created = (try? c.decodeIfPresent(String.self, forKey: .created)) ?? ""
        self.architecture = (try? c.decodeIfPresent(String.self, forKey: .architecture)) ?? ""
        self.os = (try? c.decodeIfPresent(String.self, forKey: .os)) ?? ""
        self.size = (try? c.decodeIfPresent(Int64.self, forKey: .size)) ?? 0
        self.author = (try? c.decodeIfPresent(String.self, forKey: .author)) ?? ""
        self.comment = (try? c.decodeIfPresent(String.self, forKey: .comment)) ?? ""
        self.repoTags = try? c.decodeIfPresent([String].self, forKey: .repoTags)
        self.repoDigests = try? c.decodeIfPresent([String].self, forKey: .repoDigests)
        self.config = try? c.decodeIfPresent(ImageConfig.self, forKey: .config)
    }
}

nonisolated struct ImageConfig: Codable, Hashable, Sendable {
    let cmd: [String]?
    let env: [String]?
    let workingDir: String?
    let exposedPorts: [String: JSONValue]?
    let volumes: [String: JSONValue]?

    var entrypoint: [String]? { nil }
    var user: String? { nil }
    var labels: [String: String]? { nil }

    enum CodingKeys: String, CodingKey {
        case cmd, env, workingDir, exposedPorts, volumes
    }

    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.cmd = try? c.decodeIfPresent([String].self, forKey: .cmd)
        self.env = try? c.decodeIfPresent([String].self, forKey: .env)
        self.workingDir = try? c.decodeIfPresent(String.self, forKey: .workingDir)
        self.exposedPorts = try? c.decodeIfPresent([String: JSONValue].self, forKey: .exposedPorts)
        self.volumes = try? c.decodeIfPresent([String: JSONValue].self, forKey: .volumes)
    }
}

// MARK: - NetworkInfo

nonisolated struct NetworkInfo: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let driver: String
    let scope: String
    let isDefault: Bool
    let inUse: Bool
    let labels: [String: String]?
    let options: [String: String]?
    let created: Date?

    var isInternal: Bool { false }
    var containerCount: Int { 0 }
    var attachable: Bool? { nil }
    var ipam: NetworkIPAM? { nil }
    var containers: [String: NetworkContainer]? { nil }
    var labelsDictionary: [String: String] { labels ?? [:] }
    var optionsDictionary: [String: String] { options ?? [:] }

    enum CodingKeys: String, CodingKey {
        case id, name, driver, scope, isDefault, inUse, labels, options, created
    }

    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        self.driver = (try? c.decodeIfPresent(String.self, forKey: .driver)) ?? ""
        self.scope = (try? c.decodeIfPresent(String.self, forKey: .scope)) ?? ""
        self.isDefault = (try? c.decodeIfPresent(Bool.self, forKey: .isDefault)) ?? false
        self.inUse = (try? c.decodeIfPresent(Bool.self, forKey: .inUse)) ?? false
        self.labels = try? c.decodeIfPresent([String: String].self, forKey: .labels)
        self.options = try? c.decodeIfPresent([String: String].self, forKey: .options)
        self.created = try? c.decodeIfPresent(Date.self, forKey: .created)
    }
}

nonisolated struct NetworkIPAM: Codable, Hashable, Sendable {
    let driver: String?
    let config: [NetworkIPAMConfig]?
}

nonisolated struct NetworkIPAMConfig: Codable, Hashable, Sendable {
    let subnet: String?
    let gateway: String?
}

// MARK: - ServerEnvironment

nonisolated struct ServerEnvironment: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String?
    let apiUrl: String
    let status: String
    let enabled: Bool
    let isEdge: Bool
    let connected: Bool?
    let lastSeen: Date?
    let lastHeartbeat: Date?
    let lastPollAt: Date?
    let connectedAt: Date?

    var url: String? { apiUrl.isEmpty ? nil : apiUrl }
    var agentVersion: String? { nil }
    var isOnline: Bool? {
        let s = status.lowercased()
        return s == "online" || s == "up" || connected == true
    }

    enum CodingKeys: String, CodingKey {
        case id, name, apiUrl, status, enabled, isEdge, connected
        case lastSeen, lastHeartbeat, lastPollAt, connectedAt
    }

    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try? c.decodeIfPresent(String.self, forKey: .name)
        self.apiUrl = (try? c.decodeIfPresent(String.self, forKey: .apiUrl)) ?? ""
        self.status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? ""
        self.enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        self.isEdge = (try? c.decodeIfPresent(Bool.self, forKey: .isEdge)) ?? false
        self.connected = try? c.decodeIfPresent(Bool.self, forKey: .connected)
        self.lastSeen = try? c.decodeIfPresent(Date.self, forKey: .lastSeen)
        self.lastHeartbeat = try? c.decodeIfPresent(Date.self, forKey: .lastHeartbeat)
        self.lastPollAt = try? c.decodeIfPresent(Date.self, forKey: .lastPollAt)
        self.connectedAt = try? c.decodeIfPresent(Date.self, forKey: .connectedAt)
    }
}

// MARK: - ArcaneUser

nonisolated struct ArcaneUser: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let username: String
    let email: String?
    let displayName: String?
    let locale: String?
    let oidcSubjectId: String?
    let roles: [String]?
    let canDelete: Bool
    let requiresPasswordChange: Bool
    let createdAt: String?
    let updatedAt: String?

    var isAdmin: Bool { roles?.contains("admin") ?? false }
    var displayUsername: String { username }
    var lastLogin: String? { nil }

    enum CodingKeys: String, CodingKey {
        case id, username, email, displayName, locale, oidcSubjectId
        case roles, canDelete, requiresPasswordChange, createdAt, updatedAt
    }

    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.username = (try? c.decodeIfPresent(String.self, forKey: .username)) ?? ""
        self.email = try? c.decodeIfPresent(String.self, forKey: .email)
        self.displayName = try? c.decodeIfPresent(String.self, forKey: .displayName)
        self.locale = try? c.decodeIfPresent(String.self, forKey: .locale)
        self.oidcSubjectId = try? c.decodeIfPresent(String.self, forKey: .oidcSubjectId)
        self.roles = try? c.decodeIfPresent([String].self, forKey: .roles)
        self.canDelete = (try? c.decodeIfPresent(Bool.self, forKey: .canDelete)) ?? true
        self.requiresPasswordChange = (try? c.decodeIfPresent(Bool.self, forKey: .requiresPasswordChange)) ?? false
        self.createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
        self.updatedAt = try? c.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    nonisolated init(
        id: String,
        username: String,
        email: String? = nil,
        displayName: String? = nil,
        locale: String? = nil,
        oidcSubjectId: String? = nil,
        roles: [String]? = nil,
        canDelete: Bool = true,
        requiresPasswordChange: Bool = false,
        createdAt: String? = nil,
        updatedAt: String? = nil
    ) {
        self.id = id
        self.username = username
        self.email = email
        self.displayName = displayName
        self.locale = locale
        self.oidcSubjectId = oidcSubjectId
        self.roles = roles
        self.canDelete = canDelete
        self.requiresPasswordChange = requiresPasswordChange
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - APIKey

nonisolated struct APIKey: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let keyPrefix: String
    let isStatic: Bool
    let description: String?
    let userId: String?
    let createdAt: Date?
    let updatedAt: Date?
    let expiresAt: Date?
    let lastUsedAt: Date?

    var isProtected: Bool? { isStatic }
    var permissions: [String]? { nil }

    enum CodingKeys: String, CodingKey {
        case id, name, keyPrefix, isStatic, description, userId
        case createdAt, updatedAt, expiresAt, lastUsedAt
    }

    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        self.keyPrefix = (try? c.decodeIfPresent(String.self, forKey: .keyPrefix)) ?? ""
        self.isStatic = (try? c.decodeIfPresent(Bool.self, forKey: .isStatic)) ?? false
        self.description = try? c.decodeIfPresent(String.self, forKey: .description)
        self.userId = try? c.decodeIfPresent(String.self, forKey: .userId)
        self.createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
        self.expiresAt = try? c.decodeIfPresent(Date.self, forKey: .expiresAt)
        self.lastUsedAt = try? c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }
}

// MARK: - ContainerRegistry

nonisolated struct ContainerRegistry: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let url: String
    let username: String
    let description: String?
    let enabled: Bool
    let insecure: Bool
    let registryType: String
    let awsAccessKeyId: String?
    let awsRegion: String?
    let createdAt: Date?
    let updatedAt: Date?

    var name: String? { url }

    enum CodingKeys: String, CodingKey {
        case id, url, username, description, enabled, insecure, registryType
        case awsAccessKeyId, awsRegion, createdAt, updatedAt
    }

    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? ""
        self.username = (try? c.decodeIfPresent(String.self, forKey: .username)) ?? ""
        self.description = try? c.decodeIfPresent(String.self, forKey: .description)
        self.enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        self.insecure = (try? c.decodeIfPresent(Bool.self, forKey: .insecure)) ?? false
        self.registryType = (try? c.decodeIfPresent(String.self, forKey: .registryType)) ?? "generic"
        self.awsAccessKeyId = try? c.decodeIfPresent(String.self, forKey: .awsAccessKeyId)
        self.awsRegion = try? c.decodeIfPresent(String.self, forKey: .awsRegion)
        self.createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

// MARK: - TemplateRegistry

nonisolated struct TemplateRegistry: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let url: String
    let description: String
    let enabled: Bool
    let lastFetchError: String?

    enum CodingKeys: String, CodingKey {
        case id, name, url, description, enabled, lastFetchError
    }

    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        self.url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? ""
        self.description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? ""
        self.enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        self.lastFetchError = try? c.decodeIfPresent(String.self, forKey: .lastFetchError)
    }
}

// MARK: - ComposeTemplate

nonisolated struct ComposeTemplate: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let description: String
    let content: String
    let envContent: String?
    let isCustom: Bool
    let isRemote: Bool
    let registryId: String?
    let registry: TemplateRegistry?
    let metadata: ComposeTemplateMetadata?

    var iconUrl: String? { metadata?.iconUrl }

    enum CodingKeys: String, CodingKey {
        case id, name, description, content, envContent
        case isCustom, isRemote, registryId, registry, metadata
    }

    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        self.description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? ""
        self.content = (try? c.decodeIfPresent(String.self, forKey: .content)) ?? ""
        self.envContent = try? c.decodeIfPresent(String.self, forKey: .envContent)
        self.isCustom = (try? c.decodeIfPresent(Bool.self, forKey: .isCustom)) ?? false
        self.isRemote = (try? c.decodeIfPresent(Bool.self, forKey: .isRemote)) ?? false
        self.registryId = try? c.decodeIfPresent(String.self, forKey: .registryId)
        self.registry = try? c.decodeIfPresent(TemplateRegistry.self, forKey: .registry)
        self.metadata = try? c.decodeIfPresent(ComposeTemplateMetadata.self, forKey: .metadata)
    }
}

nonisolated struct ComposeTemplateMetadata: Codable, Hashable, Sendable {
    let iconUrl: String?
    let categories: [String]?
    let documentationUrl: String?

    enum CodingKeys: String, CodingKey {
        case iconUrl, categories, documentationUrl
    }

    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.iconUrl = try? c.decodeIfPresent(String.self, forKey: .iconUrl)
        self.categories = try? c.decodeIfPresent([String].self, forKey: .categories)
        self.documentationUrl = try? c.decodeIfPresent(String.self, forKey: .documentationUrl)
    }
}

// MARK: - ComposeTemplateContent

nonisolated struct ComposeTemplateContent: Codable, Hashable, Sendable {
    let content: String
    let envContent: String
    let template: ComposeTemplate

    enum CodingKeys: String, CodingKey {
        case content, envContent, template
    }

    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.content = (try? c.decodeIfPresent(String.self, forKey: .content)) ?? ""
        self.envContent = (try? c.decodeIfPresent(String.self, forKey: .envContent)) ?? ""
        self.template = try c.decode(ComposeTemplate.self, forKey: .template)
    }
}

// MARK: - WebhookSummary

nonisolated struct WebhookSummary: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let enabled: Bool
    let actionType: String
    let targetType: String
    let targetId: String
    let targetName: String?
    let tokenPrefix: String
    let environmentId: String
    let createdAt: Date?
    let lastTriggeredAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, actionType, targetType, targetId
        case targetName, tokenPrefix, environmentId, createdAt, lastTriggeredAt
    }

    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        self.enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        self.actionType = (try? c.decodeIfPresent(String.self, forKey: .actionType)) ?? ""
        self.targetType = (try? c.decodeIfPresent(String.self, forKey: .targetType)) ?? ""
        self.targetId = (try? c.decodeIfPresent(String.self, forKey: .targetId)) ?? ""
        self.targetName = try? c.decodeIfPresent(String.self, forKey: .targetName)
        self.tokenPrefix = (try? c.decodeIfPresent(String.self, forKey: .tokenPrefix)) ?? ""
        self.environmentId = (try? c.decodeIfPresent(String.self, forKey: .environmentId)) ?? ""
        self.createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.lastTriggeredAt = try? c.decodeIfPresent(Date.self, forKey: .lastTriggeredAt)
    }
}
