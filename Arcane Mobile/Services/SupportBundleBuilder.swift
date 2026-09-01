import Arcane
import CryptoKit
import Foundation

nonisolated enum SupportBundleCheckStatus: Equatable, Sendable {
    case passed
    case failed
    case unavailable
    case skipped
    case notSupported

    var displayValue: String {
        switch self {
        case .passed: "Passed"
        case .failed: "Failed"
        case .unavailable: "Unavailable"
        case .skipped: "Skipped"
        case .notSupported: "Not supported"
        }
    }
}

nonisolated struct SupportBundleCheckResult: Equatable, Sendable {
    let status: SupportBundleCheckStatus
    let detail: String?
}

nonisolated enum SupportBundleAuthenticationState: String, Equatable, Sendable {
    case notConfigured = "Not configured"
    case authenticating = "Authenticating"
    case signedOut = "Signed out"
    case authenticated = "Authenticated"
}

nonisolated enum SupportBundleUserRole: String, Equatable, Sendable {
    case administrator = "Administrator"
    case standard = "Standard user"
    case unavailable = "Unavailable"
}

nonisolated enum SupportBundleBackendMode: String, Equatable, Sendable {
    case legacy = "Legacy roles"
    case rbac = "RBAC"
    case unknown = "Unknown"
}

nonisolated struct SupportBundleServerDescriptor: Equatable, Sendable {
    enum Transport: String, Equatable, Sendable {
        case https = "HTTPS"
        case http = "HTTP"
        case other = "Other"
    }

    enum HostKind: String, Equatable, Sendable {
        case hostname = "Hostname"
        case localHostname = "Local hostname"
        case ipv4 = "IPv4 address"
        case ipv6 = "IPv6 address"
    }

    let address: String
    let privateID: String
    let transport: Transport
    let hostKind: HostKind
    let usesNonDefaultPort: Bool
    let usesBasePath: Bool
}

nonisolated struct SupportBundleBackendSummary: Equatable, Sendable {
    let version: String?
    let tag: String?
    let revision: String?
    let goVersion: String?
    let buildTime: String?
    let enabledFeatures: [String]
    let updateAvailable: Bool
    let newestVersion: String?
}

nonisolated struct SupportBundleDockerSummary: Equatable, Sendable {
    let serverVersion: String?
    let apiVersion: String?
    let goVersion: String?
    let operatingSystem: String?
    let os: String?
    let architecture: String?
    let kernelVersion: String?
    let driver: String?
    let cgroupDriver: String?
    let cgroupVersion: String?
    let cpuCount: Int?
    let memoryBytes: Int64?
    let containers: Int?
    let containersRunning: Int?
    let containersPaused: Int?
    let containersStopped: Int?
    let images: Int?
    let dockerRootDirectory: String?
    let securityOptions: [String]
}

nonisolated struct SupportBundleEnvironmentSummary: Equatable, Sendable {
    let id: String
    let name: String?
    let apiAddress: String
    let status: String
    let enabled: Bool
    let isEdge: Bool
    let connected: Bool?
    let edgeTransport: String?
    let lastEdgeTransport: String?
    let edgeSecurityMode: String?
    let lastSeen: Date?
    let lastHeartbeat: Date?
    let lastPollAt: Date?
    let certificateCommonName: String?
    let certificateExpiresAt: Date?
    let certificateDaysRemaining: Int?
    let certificateExpired: Bool?
    let certificateExpiringSoon: Bool?
}

nonisolated struct SupportBundleActivityMessageSummary: Equatable, Sendable {
    let createdAt: Date
    let level: String
    let message: String
    let payload: [String: JSONValue]?
}

nonisolated struct SupportBundleActivitySummary: Equatable, Sendable {
    let id: String
    let batchID: String?
    let environmentID: String
    let environmentName: String?
    let type: String
    let status: String
    let resourceType: String?
    let resourceID: String?
    let resourceName: String?
    let progress: Int?
    let step: String
    let latestMessage: String
    let error: String?
    let startedBy: String?
    let startedAt: Date
    let endedAt: Date?
    let durationMs: Int64?
    let metadata: [String: JSONValue]?
    let detailError: String?
    let messages: [SupportBundleActivityMessageSummary]
}

nonisolated struct SupportBundleDiagnostics: Equatable, Sendable {
    let backend: SupportBundleBackendSummary?
    let apiHealth: SupportBundleCheckResult
    let versionEndpoint: SupportBundleCheckResult
    let activeEnvironmentHealth: SupportBundleCheckResult
    let dockerInfoCheck: SupportBundleCheckResult
    let docker: SupportBundleDockerSummary?
    let environmentInventory: SupportBundleCheckResult
    let environments: [SupportBundleEnvironmentSummary]
    let activitySampling: SupportBundleCheckResult
    let failedActivities: [SupportBundleActivitySummary]
}

nonisolated struct SupportBundleSnapshot: Equatable, Sendable {
    let generatedAt: Date
    let appVersion: String
    let appBuild: String
    let operatingSystem: String
    let deviceClass: String
    let localeIdentifier: String
    let timeZoneIdentifier: String
    let authenticationState: SupportBundleAuthenticationState
    let userRole: SupportBundleUserRole
    let userID: String?
    let username: String?
    let assignedRoles: [String]
    let backendMode: SupportBundleBackendMode
    let server: SupportBundleServerDescriptor?
    let serverURLConfigured: Bool
    let clientConfigured: Bool
    let connectionWarning: String?
    let activeEnvironmentID: String
    let activeEnvironmentName: String
    let capabilitiesLoaded: Bool
    let supportsActivities: Bool
    let supportsRoleManagement: Bool
    let permissionsManifestLoaded: Bool
    let supportsExtendedMobileAPI: Bool
    let supportsMobilePush: Bool
    let diagnostics: SupportBundleDiagnostics
}

nonisolated struct SupportBundleReport: Equatable, Sendable {
    let text: String
    let filename: String
}

nonisolated enum SupportBundleBuilder {
    static let maximumFailedActivities = 10
    static let maximumActivityMessages = 50

    static func serverDescriptor(for url: URL, fingerprintSalt: String) -> SupportBundleServerDescriptor {
        let address = sanitizedAddress(from: url.absoluteString)
        let identityURL = URL(string: address) ?? url
        let canonical = ServerCacheIdentity.canonical(for: identityURL)
        let privateID = "srv-" + shortHash("\(fingerprintSalt)\u{0}\(canonical)")
        let scheme = url.scheme?.lowercased()
        let transport: SupportBundleServerDescriptor.Transport = switch scheme {
        case "https": .https
        case "http": .http
        default: .other
        }
        let host = url.host?.lowercased() ?? ""
        let hostKind: SupportBundleServerDescriptor.HostKind
        if host.contains(":") {
            hostKind = .ipv6
        } else if isIPv4(host) {
            hostKind = .ipv4
        } else if host == "localhost" || host.hasSuffix(".local") {
            hostKind = .localHostname
        } else {
            hostKind = .hostname
        }

        let defaultPort: Int? = switch scheme {
        case "https": 443
        case "http": 80
        default: nil
        }
        let path = url.path

        return SupportBundleServerDescriptor(
            address: address,
            privateID: privateID,
            transport: transport,
            hostKind: hostKind,
            usesNonDefaultPort: url.port.map { $0 != defaultPort } ?? false,
            usesBasePath: !path.isEmpty && path != "/"
        )
    }

    static func sanitizedAddress(from rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), components.host != nil else {
            return reportValue(trimmed)
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string.map(redacted) ?? reportValue(trimmed)
    }

    static func redacted(_ value: String) -> String {
        var result = value.replacingOccurrences(
            of: #"(?i)(https?://)[^/@\s]+@"#,
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)\b(authorization|proxy-authorization)\b(\s*[:=]\s*)(?:bearer|basic)?\s*[^\s,;]+"#,
            with: "$1$2[REDACTED]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)\b(x[-_]?api[-_]?key|api[-_]?key|password|passwd|pwd|client[-_]?secret|access[-_]?token|refresh[-_]?token|token|secret|set-cookie|cookie)\b(\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;&]+)"#,
            with: "$1$2[REDACTED]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]+"#,
            with: "$1 [REDACTED]",
            options: .regularExpression
        )
        return result.replacingOccurrences(
            of: #"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}(?![A-Za-z0-9_-])"#,
            with: "[REDACTED]",
            options: .regularExpression
        )
    }

    static func makeReport(from snapshot: SupportBundleSnapshot) -> SupportBundleReport {
        var lines = [
            "Arcane Mobile Support Bundle",
            "Format: 2",
            "Generated: \(snapshot.generatedAt.ISO8601Format())",
            "",
            "[App]",
            "Version: \(reportValue(snapshot.appVersion))",
            "Build: \(reportValue(snapshot.appBuild))",
            "Operating system: \(reportValue(snapshot.operatingSystem))",
            "Device class: \(reportValue(snapshot.deviceClass))",
            "Locale: \(reportValue(snapshot.localeIdentifier))",
            "Time zone: \(reportValue(snapshot.timeZoneIdentifier))",
            "",
            "[Session]",
            "Authentication: \(snapshot.authenticationState.rawValue)",
            "User role: \(snapshot.userRole.rawValue)",
            "User ID: \(reportValue(snapshot.userID))",
            "Username: \(reportValue(snapshot.username))",
            "Assigned roles: \(listValue(snapshot.assignedRoles))",
            "Backend API mode: \(snapshot.backendMode.rawValue)",
            "Active environment ID: \(reportValue(snapshot.activeEnvironmentID))",
            "Active environment name: \(reportValue(snapshot.activeEnvironmentName))",
            "Connection warning: \(snapshot.connectionWarning.map { reportValue($0) } ?? "None")",
            "",
            "[Server]"
        ]

        if let server = snapshot.server {
            lines.append(contentsOf: [
                "Address: \(reportValue(server.address))",
                "Stable server ID: \(server.privateID)",
                "Transport: \(server.transport.rawValue)",
                "Host form: \(server.hostKind.rawValue)",
                "Non-default port: \(yesNo(server.usesNonDefaultPort))",
                "Base path: \(yesNo(server.usesBasePath))"
            ])
        } else {
            lines.append(contentsOf: [
                "Address: Unavailable",
                "Stable server ID: Unavailable"
            ])
        }

        if let backend = snapshot.diagnostics.backend {
            lines.append(contentsOf: [
                "Arcane version: \(safeVersion(backend.version) ?? "Unavailable")",
                "Arcane tag: \(reportValue(backend.tag))",
                "Arcane revision: \(reportValue(backend.revision))",
                "Arcane Go version: \(reportValue(backend.goVersion))",
                "Arcane build time: \(reportValue(backend.buildTime))",
                "Enabled backend features: \(listValue(backend.enabledFeatures))",
                "Arcane update available: \(yesNo(backend.updateAvailable))",
                "Newest Arcane version: \(safeVersion(backend.newestVersion) ?? "Unavailable")"
            ])
        } else {
            lines.append("Arcane version: Unavailable")
        }

        lines.append(contentsOf: [
            "",
            "[Capabilities]",
            "Capability metadata: \(snapshot.capabilitiesLoaded ? "Loaded" : "Unavailable")",
            "Activities: \(supportValue(snapshot.supportsActivities, known: snapshot.capabilitiesLoaded))",
            "Role management: \(supportValue(snapshot.supportsRoleManagement, known: snapshot.capabilitiesLoaded))",
            "Permission manifest: \(permissionManifestValue(snapshot))",
            "Extended mobile API: \(supportValue(snapshot.supportsExtendedMobileAPI, known: snapshot.capabilitiesLoaded))",
            "Mobile push API: \(supportValue(snapshot.supportsMobilePush, known: snapshot.capabilitiesLoaded))",
            "",
            "[Endpoint Diagnostics]",
            "Server URL configured: \(snapshot.serverURLConfigured ? "Passed" : "Failed")",
            "Client configured: \(snapshot.clientConfigured ? "Passed" : "Failed")",
            "Authenticated session: \(snapshot.authenticationState == .authenticated ? "Passed" : "Failed")"
        ])
        appendCheck("API health", snapshot.diagnostics.apiHealth, to: &lines)
        appendCheck("Version endpoint", snapshot.diagnostics.versionEndpoint, to: &lines)
        appendCheck("Active environment health", snapshot.diagnostics.activeEnvironmentHealth, to: &lines)
        appendCheck("Docker info endpoint", snapshot.diagnostics.dockerInfoCheck, to: &lines)
        appendCheck("Environment inventory endpoint", snapshot.diagnostics.environmentInventory, to: &lines)
        appendCheck("Failed activity endpoint", snapshot.diagnostics.activitySampling, to: &lines)

        lines.append(contentsOf: ["", "[Active Docker Daemon]"])
        if let docker = snapshot.diagnostics.docker {
            lines.append(contentsOf: [
                "Docker server version: \(reportValue(docker.serverVersion))",
                "Docker API version: \(reportValue(docker.apiVersion))",
                "Docker Go version: \(reportValue(docker.goVersion))",
                "Operating system: \(reportValue(docker.operatingSystem))",
                "OS: \(reportValue(docker.os))",
                "Architecture: \(reportValue(docker.architecture))",
                "Kernel: \(reportValue(docker.kernelVersion))",
                "Storage driver: \(reportValue(docker.driver))",
                "Cgroup driver: \(reportValue(docker.cgroupDriver))",
                "Cgroup version: \(reportValue(docker.cgroupVersion))",
                "CPUs: \(numberValue(docker.cpuCount))",
                "Memory bytes: \(numberValue(docker.memoryBytes))",
                "Containers: \(numberValue(docker.containers))",
                "Containers running: \(numberValue(docker.containersRunning))",
                "Containers paused: \(numberValue(docker.containersPaused))",
                "Containers stopped: \(numberValue(docker.containersStopped))",
                "Images: \(numberValue(docker.images))",
                "Docker root directory: \(reportValue(docker.dockerRootDirectory))",
                "Security options: \(listValue(docker.securityOptions))"
            ])
        } else {
            lines.append("Docker information: Unavailable")
        }

        lines.append(contentsOf: [
            "",
            "[Environment Inventory]",
            "Count returned: \(String(snapshot.diagnostics.environments.count))"
        ])
        for (index, environment) in snapshot.diagnostics.environments.enumerated() {
            lines.append(contentsOf: [
                "",
                "Environment \(String(index + 1)):",
                "  ID: \(reportValue(environment.id))",
                "  Name: \(reportValue(environment.name))",
                "  API address: \(reportValue(environment.apiAddress))",
                "  Status: \(reportValue(environment.status))",
                "  Enabled: \(yesNo(environment.enabled))",
                "  Edge environment: \(yesNo(environment.isEdge))",
                "  Connected: \(optionalYesNo(environment.connected))",
                "  Edge transport: \(reportValue(environment.edgeTransport))",
                "  Last edge transport: \(reportValue(environment.lastEdgeTransport))",
                "  Edge security mode: \(reportValue(environment.edgeSecurityMode))",
                "  Last seen: \(dateValue(environment.lastSeen))",
                "  Last heartbeat: \(dateValue(environment.lastHeartbeat))",
                "  Last poll: \(dateValue(environment.lastPollAt))",
                "  Certificate common name: \(reportValue(environment.certificateCommonName))",
                "  Certificate expires: \(dateValue(environment.certificateExpiresAt))",
                "  Certificate days remaining: \(numberValue(environment.certificateDaysRemaining))",
                "  Certificate expired: \(optionalYesNo(environment.certificateExpired))",
                "  Certificate expiring soon: \(optionalYesNo(environment.certificateExpiringSoon))"
            ])
        }

        let activities = Array(snapshot.diagnostics.failedActivities.prefix(maximumFailedActivities))
        lines.append(contentsOf: [
            "",
            "[Recent Failed Activities]",
            "Count included: \(String(activities.count))"
        ])
        if activities.isEmpty {
            lines.append("No recent failed activities returned")
        }
        for (index, activity) in activities.enumerated() {
            lines.append(contentsOf: [
                "",
                "Failed activity \(String(index + 1)):",
                "  ID: \(reportValue(activity.id))",
                "  Batch ID: \(reportValue(activity.batchID))",
                "  Environment ID: \(reportValue(activity.environmentID))",
                "  Environment name: \(reportValue(activity.environmentName))",
                "  Type: \(reportValue(activity.type))",
                "  Status: \(reportValue(activity.status))",
                "  Resource type: \(reportValue(activity.resourceType))",
                "  Resource ID: \(reportValue(activity.resourceID))",
                "  Resource name: \(reportValue(activity.resourceName))",
                "  Progress: \(activity.progress.map { "\(String($0))%" } ?? "Unavailable")",
                "  Step: \(reportValue(activity.step))",
                "  Latest message: \(reportValue(activity.latestMessage, maximumLength: 4_000))",
                "  Error: \(reportValue(activity.error, maximumLength: 4_000))",
                "  Started by: \(reportValue(activity.startedBy))",
                "  Started: \(activity.startedAt.ISO8601Format())",
                "  Ended: \(dateValue(activity.endedAt))",
                "  Duration milliseconds: \(numberValue(activity.durationMs))",
                "  Detail request error: \(activity.detailError.map { reportValue($0, maximumLength: 4_000) } ?? "None")"
            ])
            if let metadata = activity.metadata, !metadata.isEmpty {
                lines.append("  Metadata: \(jsonText(metadata))")
            } else {
                lines.append("  Metadata: None")
            }

            let messages = Array(activity.messages.prefix(maximumActivityMessages))
            lines.append("  Messages included: \(String(messages.count))")
            for message in messages {
                lines.append(
                    "    - \(message.createdAt.ISO8601Format()) [\(reportValue(message.level))] "
                        + reportValue(message.message, maximumLength: 4_000)
                )
                if let payload = message.payload, !payload.isEmpty {
                    lines.append("      Payload: \(jsonText(payload))")
                }
            }
        }
        lines.append("")

        return SupportBundleReport(
            text: lines.joined(separator: "\n"),
            filename: filename(for: snapshot.generatedAt)
        )
    }

    private static func appendCheck(
        _ label: String,
        _ check: SupportBundleCheckResult,
        to lines: inout [String]
    ) {
        lines.append("\(label): \(check.status.displayValue)")
        if let detail = check.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            lines.append("\(label) detail: \(reportValue(detail, maximumLength: 4_000))")
        }
    }

    private static func supportValue(_ value: Bool, known: Bool) -> String {
        guard known else { return "Unknown" }
        return value ? "Supported" : "Not supported"
    }

    private static func permissionManifestValue(_ snapshot: SupportBundleSnapshot) -> String {
        guard snapshot.backendMode == .rbac else { return "Not applicable" }
        return snapshot.permissionsManifestLoaded ? "Loaded" : "Unavailable"
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }

    private static func optionalYesNo(_ value: Bool?) -> String {
        value.map(yesNo) ?? "Unavailable"
    }

    private static func numberValue<T: BinaryInteger>(_ value: T?) -> String {
        guard let value else { return "Unavailable" }
        return String(value)
    }

    private static func dateValue(_ value: Date?) -> String {
        value?.ISO8601Format() ?? "Unavailable"
    }

    private static func listValue(_ values: [String]) -> String {
        let sanitized = values
            .map { reportValue($0) }
            .filter { $0 != "Unavailable" }
            .sorted()
        return sanitized.isEmpty ? "None" : sanitized.joined(separator: ", ")
    }

    private static func reportValue(_ value: String?, maximumLength: Int = 2_000) -> String {
        guard let value else { return "Unavailable" }
        let singleLine = value
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !singleLine.isEmpty else { return "Unavailable" }
        let sanitized = redacted(singleLine)
        guard sanitized.count > maximumLength else { return sanitized }
        return String(sanitized.prefix(maximumLength)) + "…"
    }

    private static func safeVersion(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-+"))
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return trimmed
    }

    private static func jsonText(_ object: [String: JSONValue]) -> String {
        let sanitized = sanitizedJSONValue(.object(object), key: nil, depth: 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(sanitized),
              let text = String(data: data, encoding: .utf8) else {
            return "Unavailable"
        }
        return reportValue(text, maximumLength: 12_000)
    }

    private static func sanitizedJSONValue(
        _ value: JSONValue,
        key: String?,
        depth: Int
    ) -> JSONValue {
        if let key, isSensitiveKey(key) {
            return .string("[REDACTED]")
        }
        guard depth < 8 else { return .string("[TRUNCATED]") }

        switch value {
        case .null, .bool, .number:
            return value
        case .string(let string):
            return .string(reportValue(string, maximumLength: 4_000))
        case .array(let values):
            return .array(
                values.prefix(100).map {
                    sanitizedJSONValue($0, key: nil, depth: depth + 1)
                }
            )
        case .object(let object):
            var sanitized: [String: JSONValue] = [:]
            for (childKey, childValue) in object.sorted(by: { $0.key < $1.key }).prefix(100) {
                sanitized[reportValue(childKey, maximumLength: 256)] = sanitizedJSONValue(
                    childValue,
                    key: childKey,
                    depth: depth + 1
                )
            }
            return .object(sanitized)
        }
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter(\.isLetter)
        return [
            "password",
            "passwd",
            "pwd",
            "secret",
            "token",
            "apikey",
            "authorization",
            "cookie",
            "credential",
            "privatekey",
            "clientsecret",
            "accesskey"
        ].contains { normalized.contains($0) }
    }

    private static func shortHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isIPv4(_ host: String) -> Bool {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return false }
        return components.allSatisfy { component in
            guard let octet = Int(component), (0...255).contains(octet) else { return false }
            return String(octet) == component || component == "0"
        }
    }

    private static func filename(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "Arcane-Mobile-Support-%04d%02d%02d-%02d%02d%02dZ.txt",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
    }
}

nonisolated enum SupportBundleCollector {
    private struct VersionProbe: Sendable {
        let summary: SupportBundleBackendSummary?
        let check: SupportBundleCheckResult
    }

    private struct DockerProbe: Sendable {
        let summary: SupportBundleDockerSummary?
        let check: SupportBundleCheckResult
    }

    private struct EnvironmentProbe: Sendable {
        let environments: [SupportBundleEnvironmentSummary]
        let check: SupportBundleCheckResult
    }

    private struct ActivityProbe: Sendable {
        let activities: [SupportBundleActivitySummary]
        let check: SupportBundleCheckResult
    }

    static func collect(
        client: ArcaneClient?,
        activeEnvironmentID: EnvironmentID,
        activeEnvironmentName: String,
        supportsActivities: Bool
    ) async -> SupportBundleDiagnostics {
        guard let client else {
            let skipped = SupportBundleCheckResult(
                status: .skipped,
                detail: "No configured API client"
            )
            return SupportBundleDiagnostics(
                backend: nil,
                apiHealth: skipped,
                versionEndpoint: skipped,
                activeEnvironmentHealth: skipped,
                dockerInfoCheck: skipped,
                docker: nil,
                environmentInventory: skipped,
                environments: [],
                activitySampling: supportsActivities
                    ? skipped
                    : SupportBundleCheckResult(
                        status: .notSupported,
                        detail: "Backend does not advertise the activities API"
                    ),
                failedActivities: []
            )
        }

        async let apiHealth = probeAPIHealth(client: client)
        async let version = probeVersion(client: client)
        async let environmentHealth = probeEnvironmentHealth(
            client: client,
            environmentID: activeEnvironmentID
        )
        async let docker = probeDockerInfo(
            client: client,
            environmentID: activeEnvironmentID
        )
        async let environments = probeEnvironments(client: client)
        async let activities = probeActivities(
            client: client,
            environmentID: activeEnvironmentID,
            environmentName: activeEnvironmentName,
            supported: supportsActivities
        )

        let results = await (
            apiHealth,
            version,
            environmentHealth,
            docker,
            environments,
            activities
        )
        return SupportBundleDiagnostics(
            backend: results.1.summary,
            apiHealth: results.0,
            versionEndpoint: results.1.check,
            activeEnvironmentHealth: results.2,
            dockerInfoCheck: results.3.check,
            docker: results.3.summary,
            environmentInventory: results.4.check,
            environments: results.4.environments,
            activitySampling: results.5.check,
            failedActivities: results.5.activities
        )
    }

    private static func probeAPIHealth(client: ArcaneClient) async -> SupportBundleCheckResult {
        do {
            let response = try await client.system.apiHealth()
            let status = response.status.trimmingCharacters(in: .whitespacesAndNewlines)
            return SupportBundleCheckResult(
                status: status.uppercased() == "UP" ? .passed : .failed,
                detail: "Reported status: \(status.isEmpty ? "empty" : status)"
            )
        } catch {
            return failedCheck(error)
        }
    }

    private static func probeVersion(client: ArcaneClient) async -> VersionProbe {
        do {
            let response = try await client.version.appVersion()
            let version = response.currentVersion.isEmpty
                ? response.displayVersion
                : response.currentVersion
            let revision = response.shortRevision.isEmpty
                ? response.revision
                : response.shortRevision
            return VersionProbe(
                summary: SupportBundleBackendSummary(
                    version: version,
                    tag: response.currentTag,
                    revision: revision,
                    goVersion: response.goVersion,
                    buildTime: response.buildTime,
                    enabledFeatures: response.enabledFeatures ?? [],
                    updateAvailable: response.updateAvailable,
                    newestVersion: response.newestVersion
                ),
                check: SupportBundleCheckResult(status: .passed, detail: nil)
            )
        } catch {
            return VersionProbe(summary: nil, check: failedCheck(error))
        }
    }

    private static func probeEnvironmentHealth(
        client: ArcaneClient,
        environmentID: EnvironmentID
    ) async -> SupportBundleCheckResult {
        do {
            try await client.system.health(envID: environmentID)
            return SupportBundleCheckResult(status: .passed, detail: nil)
        } catch {
            return failedCheck(error)
        }
    }

    private static func probeDockerInfo(
        client: ArcaneClient,
        environmentID: EnvironmentID
    ) async -> DockerProbe {
        do {
            let info = try await RemoteDataLimits.boundedDockerInfo(
                client: client,
                environmentID: environmentID
            )
            let values = info.info
            let securityOptions: [String]
            if case .array(let items)? = values?["SecurityOptions"] {
                securityOptions = items.compactMap(\.stringValue)
            } else {
                securityOptions = []
            }
            return DockerProbe(
                summary: SupportBundleDockerSummary(
                    serverVersion: info.serverVersion,
                    apiVersion: info.apiVersion,
                    goVersion: info.goVersion,
                    operatingSystem: info.operatingSystem,
                    os: info.os,
                    architecture: info.arch,
                    kernelVersion: values?["KernelVersion"]?.stringValue,
                    driver: values?["Driver"]?.stringValue,
                    cgroupDriver: values?["CgroupDriver"]?.stringValue,
                    cgroupVersion: values?["CgroupVersion"]?.stringValue,
                    cpuCount: info.ncpu,
                    memoryBytes: info.memTotal,
                    containers: values?["Containers"]?.intValue,
                    containersRunning: values?["ContainersRunning"]?.intValue,
                    containersPaused: values?["ContainersPaused"]?.intValue,
                    containersStopped: values?["ContainersStopped"]?.intValue,
                    images: values?["Images"]?.intValue,
                    dockerRootDirectory: values?["DockerRootDir"]?.stringValue,
                    securityOptions: securityOptions
                ),
                check: SupportBundleCheckResult(status: .passed, detail: nil)
            )
        } catch {
            return DockerProbe(summary: nil, check: failedCheck(error))
        }
    }

    private static func probeEnvironments(client: ArcaneClient) async -> EnvironmentProbe {
        do {
            let environments: [Arcane.Environment] = try await PaginationLoader.collect(
                maximumItems: RemoteDataLimits.maximumEnvironments
            ) { start, limit in
                let response = try await client.environments.list(
                    query: .init(
                        start: start,
                        limit: limit,
                        sortBy: "name",
                        sortOrder: .ascending
                    )
                )
                return ResourcePage(items: response.data, pagination: response.pagination)
            }
            let summaries = environments.map { environment in
                let certificate = environment.edgeMTLSCertificate
                return SupportBundleEnvironmentSummary(
                    id: environment.id,
                    name: environment.name,
                    apiAddress: SupportBundleBuilder.sanitizedAddress(from: environment.apiUrl),
                    status: environment.status,
                    enabled: environment.enabled,
                    isEdge: environment.isEdge,
                    connected: environment.connected,
                    edgeTransport: environment.edgeTransport,
                    lastEdgeTransport: environment.lastEdgeTransport,
                    edgeSecurityMode: environment.edgeSecurityMode,
                    lastSeen: environment.lastSeen,
                    lastHeartbeat: environment.lastHeartbeat,
                    lastPollAt: environment.lastPollAt,
                    certificateCommonName: certificate?.commonName,
                    certificateExpiresAt: certificate?.expiresAt,
                    certificateDaysRemaining: certificate?.daysRemaining,
                    certificateExpired: certificate?.expired,
                    certificateExpiringSoon: certificate?.expiringSoon
                )
            }
            return EnvironmentProbe(
                environments: summaries,
                check: SupportBundleCheckResult(
                    status: .passed,
                    detail: "Returned \(String(summaries.count)) environment(s)"
                )
            )
        } catch {
            return EnvironmentProbe(environments: [], check: failedCheck(error))
        }
    }

    private static func probeActivities(
        client: ArcaneClient,
        environmentID: EnvironmentID,
        environmentName: String,
        supported: Bool
    ) async -> ActivityProbe {
        guard supported else {
            return ActivityProbe(
                activities: [],
                check: SupportBundleCheckResult(
                    status: .notSupported,
                    detail: "Backend does not advertise the activities API"
                )
            )
        }

        do {
            let response = try await client.activities.listPaginated(
                envID: environmentID,
                order: .descending,
                start: 0,
                limit: SupportBundleBuilder.maximumFailedActivities,
                status: .failed
            )
            guard response.success else {
                return ActivityProbe(
                    activities: [],
                    check: SupportBundleCheckResult(
                        status: .failed,
                        detail: "Activity list returned success=false"
                    )
                )
            }

            let recent = Array(response.data.prefix(SupportBundleBuilder.maximumFailedActivities))
            var indexed: [(Int, SupportBundleActivitySummary)] = []
            await withTaskGroup(of: (Int, SupportBundleActivitySummary).self) { group in
                for (index, activity) in recent.enumerated() {
                    group.addTask {
                        do {
                            let detail = try await client.activities.detail(
                                envID: environmentID,
                                activityID: activity.id,
                                limit: SupportBundleBuilder.maximumActivityMessages
                            )
                            return (
                                index,
                                activitySummary(
                                    detail.activity,
                                    messages: detail.messages,
                                    environmentName: environmentName,
                                    detailError: nil
                                )
                            )
                        } catch {
                            return (
                                index,
                                activitySummary(
                                    activity,
                                    messages: [],
                                    environmentName: environmentName,
                                    detailError: diagnosticErrorDetail(error)
                                )
                            )
                        }
                    }
                }
                for await value in group {
                    indexed.append(value)
                }
            }
            indexed.sort { $0.0 < $1.0 }
            let summaries = indexed.map(\.1)
            let detailFailures = summaries.count(where: { $0.detailError != nil })
            let messageCount = summaries.reduce(0) { $0 + $1.messages.count }
            var detail = "Returned \(String(summaries.count)) recent failed activities"
            detail += " and \(String(messageCount)) messages"
            if detailFailures > 0 {
                detail += "; \(String(detailFailures)) detail request(s) failed"
            }
            return ActivityProbe(
                activities: summaries,
                check: SupportBundleCheckResult(status: .passed, detail: detail)
            )
        } catch {
            return ActivityProbe(activities: [], check: failedCheck(error))
        }
    }

    private static func activitySummary(
        _ activity: Activity,
        messages: [ActivityMessage],
        environmentName: String,
        detailError: String?
    ) -> SupportBundleActivitySummary {
        let sourceName = activity.sourceEnvironmentName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let startedBy = activity.startedBy.map { initiator in
            let displayName = initiator.displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let displayName, !displayName.isEmpty else { return initiator.username }
            return displayName
        }
        return SupportBundleActivitySummary(
            id: activity.id,
            batchID: activity.batchID,
            environmentID: activity.sourceEnvironmentID ?? activity.environmentID,
            environmentName: sourceName?.isEmpty == false ? sourceName : environmentName,
            type: activity.type.rawValue,
            status: activity.status.rawValue,
            resourceType: activity.resourceType,
            resourceID: activity.resourceID,
            resourceName: activity.resourceName,
            progress: activity.progress,
            step: activity.step,
            latestMessage: activity.latestMessage,
            error: activity.error,
            startedBy: startedBy,
            startedAt: activity.startedAt,
            endedAt: activity.endedAt,
            durationMs: activity.durationMs,
            metadata: activity.metadata,
            detailError: detailError,
            messages: messages.prefix(SupportBundleBuilder.maximumActivityMessages).map { message in
                SupportBundleActivityMessageSummary(
                    createdAt: message.createdAt,
                    level: message.level.rawValue,
                    message: message.message,
                    payload: message.payload
                )
            }
        )
    }

    private static func failedCheck(_ error: Error) -> SupportBundleCheckResult {
        SupportBundleCheckResult(
            status: .unavailable,
            detail: diagnosticErrorDetail(error)
        )
    }

    private static func diagnosticErrorDetail(_ error: Error) -> String {
        if let arcaneError = error as? ArcaneError {
            switch arcaneError {
            case .unauthorized:
                return "ArcaneError.unauthorized"
            case .forbidden:
                return "ArcaneError.forbidden"
            case .notFound:
                return "ArcaneError.notFound"
            case .conflict(let message):
                return "ArcaneError.conflict: \(message ?? "No message")"
            case .validation(let fields):
                let values = fields.sorted(by: { $0.key < $1.key }).map { key, messages in
                    "\(key)=\(messages.joined(separator: " | "))"
                }
                return "ArcaneError.validation: \(values.joined(separator: "; "))"
            case .rateLimited(let retryAfter):
                let retryValue = retryAfter.map { String($0) } ?? "Unavailable"
                return "ArcaneError.rateLimited: retryAfter=\(retryValue)"
            case .server(let code, let message):
                return "ArcaneError.server \(code): \(message)"
            case .transport(let message):
                return "ArcaneError.transport: \(message)"
            case .decoding(let message):
                return "ArcaneError.decoding: \(message)"
            case .unknown(let statusCode, let body):
                return "ArcaneError.unknown HTTP \(String(statusCode)): \(body)"
            }
        }

        let nsError = error as NSError
        return "\(nsError.domain) \(String(nsError.code)): \(nsError.localizedDescription)"
    }
}
