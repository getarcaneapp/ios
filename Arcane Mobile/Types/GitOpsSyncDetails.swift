import Foundation

/// A GitOps sync read leniently from the server's JSON, so a server missing
/// newer fields (backup mode, pre-deploy hooks) still renders.
nonisolated struct GitOpsSyncDetails: Hashable, Sendable, Identifiable {
    enum Mode: String, Sendable {
        case deploy
        case backup
    }

    /// A status string `ResourceStatusBadge` understands, plus the text to show.
    struct StatusPresentation: Hashable, Sendable {
        let status: String
        let label: String
    }

    let id: String
    let name: String
    let environmentID: String?
    let mode: Mode
    let repositoryID: String?
    let repositoryName: String?
    let repositoryURL: String?
    let branch: String?
    let composePath: String?
    let targetType: String?
    let projectName: String?
    let projectID: String?
    let autoSync: Bool
    let syncIntervalMinutes: Int
    let syncDirectory: Bool
    let pullImageAfterSync: Bool
    let redeployAfterSync: Bool
    let syncedFiles: [String]
    let maxSyncFiles: Int
    let maxSyncTotalSize: Int64
    let maxSyncBinarySize: Int64
    let lastSyncAt: Date?
    let lastSyncStatus: String?
    let lastSyncError: String?
    let lastSyncCommit: String?
    let backupDirectory: String?
    let backupPaths: [String]
    let backupOnSave: Bool
    let backupPending: Bool
    let backupState: String
    let backupFailureReason: String?
    let lastBackupAt: Date?
    let preDeployScriptPath: String?
    let preDeployRunnerImage: String?
    let preDeployLastRunStatus: String?
    let preDeployLastRunAt: Date?
    let createdAt: Date?
    let updatedAt: Date?

    init(resource: DynamicResource) {
        self.init(values: resource.values, fallbackID: resource.id)
    }

    init(values: [String: AnyJSONValue], fallbackID: String) {
        let reader = Reader(values: values)
        id = reader.string("id") ?? fallbackID
        name = reader.string("name") ?? reader.string("projectName") ?? fallbackID
        environmentID = reader.string("environmentId")
        mode = reader.string("mode").flatMap(Mode.init(rawValue:)) ?? .deploy
        let repository = Reader(values: values["repository"]?.objectValue ?? [:])
        repositoryID = reader.string("repositoryId") ?? repository.string("id")
        repositoryName = repository.string("name")
        repositoryURL = repository.string("url")
        branch = reader.string("branch")
        composePath = reader.string("composePath")
        targetType = reader.string("targetType")
        projectName = reader.string("projectName")
        projectID = reader.string("projectId")
        autoSync = reader.bool("autoSync")
        syncIntervalMinutes = Int(reader.integer("syncInterval"))
        syncDirectory = reader.bool("syncDirectory")
        pullImageAfterSync = reader.bool("pullImageAfterSync")
        redeployAfterSync = reader.bool("redeployAfterSync")
        syncedFiles = Self.decodeFileList(reader.string("syncedFiles"))
        maxSyncFiles = Int(reader.integer("maxSyncFiles"))
        maxSyncTotalSize = reader.integer("maxSyncTotalSize")
        maxSyncBinarySize = reader.integer("maxSyncBinarySize")
        lastSyncAt = reader.date("lastSyncAt")
        lastSyncStatus = reader.string("lastSyncStatus")
        lastSyncError = reader.string("lastSyncError")
        lastSyncCommit = reader.string("lastSyncCommit")
        backupDirectory = reader.string("backupDirectory")
        backupPaths = reader.stringArray("backupPaths")
        backupOnSave = reader.bool("backupOnSave")
        backupPending = reader.bool("backupPending")
        backupState = reader.string("backupState") ?? "never"
        backupFailureReason = reader.string("backupFailureReason")
        lastBackupAt = reader.date("lastBackupAt")
        preDeployScriptPath = reader.string("preDeployScriptPath")
        preDeployRunnerImage = reader.string("preDeployRunnerImage")
        preDeployLastRunStatus = reader.string("preDeployLastRunStatus")
        preDeployLastRunAt = reader.date("preDeployLastRunAt")
        createdAt = reader.date("createdAt")
        updatedAt = reader.date("updatedAt")
    }

    var isBackup: Bool { mode == .backup }

    var isSwarmStack: Bool { targetType == "swarm_stack" }

    var targetLabel: String {
        switch targetType {
        case nil, "project": "Project"
        case "swarm_stack": "Swarm Stack"
        case let other?: other.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// The first seven characters of a full commit hash.
    var shortCommit: String? {
        guard let lastSyncCommit else { return nil }
        return String(lastSyncCommit.prefix(7))
    }

    var syncIntervalDescription: String {
        Self.intervalDescription(minutes: syncIntervalMinutes)
    }

    /// Deploy syncs report the last pull; backups report the backup lifecycle.
    var statusPresentation: StatusPresentation {
        isBackup ? Self.backupStatePresentation(backupState) : Self.syncStatusPresentation(lastSyncStatus)
    }

    /// The last error, shown only while the sync is in a failed state.
    var visibleError: String? {
        guard let lastSyncError else { return nil }
        if isBackup {
            return ["failed", "needs_attention"].contains(backupState) ? lastSyncError : nil
        }
        return lastSyncStatus == "failed" ? lastSyncError : nil
    }

    var backupFailureDescription: String? {
        guard let backupFailureReason else { return nil }
        switch backupFailureReason {
        case "repository": return "Repository unreachable"
        case "auth": return "Authentication failed"
        case "project_missing": return "Project missing"
        case "snapshot": return "Snapshot failed"
        case "unreadable_files": return "Unreadable files"
        case "limits": return "File limits exceeded"
        case "conflict": return "Remote changes conflict"
        case "destination_occupied": return "Destination already in use"
        case "push_rejected": return "Push rejected"
        default: return backupFailureReason.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var repositoryWebURL: URL? {
        repositoryURL.flatMap(Self.webURL(forRepository:))
    }

    var commitURL: URL? {
        guard let repositoryURL, let lastSyncCommit else { return nil }
        return Self.commitURL(repository: repositoryURL, commit: lastSyncCommit)
    }

    // MARK: - Formatting

    static func syncStatusPresentation(_ status: String?) -> StatusPresentation {
        switch status?.lowercased() {
        case "success": StatusPresentation(status: "success", label: "Synced")
        case "failed": StatusPresentation(status: "failed", label: "Failed")
        case "pending": StatusPresentation(status: "starting", label: "Pending")
        default: StatusPresentation(status: "", label: "Not Synced")
        }
    }

    static func backupStatePresentation(_ state: String) -> StatusPresentation {
        switch state {
        case "pending": StatusPresentation(status: "partial", label: "Pending Changes")
        case "backing_up": StatusPresentation(status: "starting", label: "Backing Up")
        case "backed_up": StatusPresentation(status: "success", label: "Backed Up")
        case "paused": StatusPresentation(status: "paused", label: "Paused")
        case "failed": StatusPresentation(status: "failed", label: "Failed")
        case "needs_attention": StatusPresentation(status: "error", label: "Needs Attention")
        default: StatusPresentation(status: "", label: "Not Backed Up")
        }
    }

    static func intervalDescription(minutes: Int) -> String {
        guard minutes > 0 else { return "Manual" }
        let (value, unit): (Int, String) =
            if minutes % 1440 == 0 {
                (minutes / 1440, "day")
            } else if minutes % 60 == 0 {
                (minutes / 60, "hour")
            } else {
                (minutes, "minute")
            }
        return value == 1 ? "Every \(unit)" : "Every \(value) \(unit)s"
    }

    /// The browsable https URL for an https, ssh://, or scp-style Git remote.
    static func webURL(forRepository raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let host: String
        let path: String
        if trimmed.contains("://") {
            guard let components = URLComponents(string: trimmed), let hostname = components.host,
                !hostname.isEmpty
            else { return nil }
            let scheme = components.scheme?.lowercased()
            let isWeb = scheme == "http" || scheme == "https"
            // An ssh:// port is the SSH port, not the forge's web port.
            host = isWeb ? hostname + (components.port.map { ":\($0)" } ?? "") : hostname
            path = components.path
            let stripped = stripGitSuffix(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            guard !stripped.isEmpty else { return nil }
            return URL(string: "\(isWeb ? scheme ?? "https" : "https")://\(host)/\(stripped)")
        }
        let withoutUser = trimmed.split(separator: "@", maxSplits: 1).last.map(String.init) ?? trimmed
        guard let separator = withoutUser.firstIndex(where: { $0 == ":" || $0 == "/" }) else { return nil }
        host = String(withoutUser[..<separator])
        path = String(withoutUser[withoutUser.index(after: separator)...])
        let stripped = stripGitSuffix(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        guard !host.isEmpty, !stripped.isEmpty else { return nil }
        return URL(string: "https://\(host)/\(stripped)")
    }

    static func commitURL(repository: String, commit: String) -> URL? {
        guard let base = webURL(forRepository: repository), let host = base.host?.lowercased(),
            let encodedCommit = commit.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
            !encodedCommit.isEmpty
        else { return nil }
        let segment =
            if host.contains("gitlab") {
                "/-/commit/"
            } else if host.contains("bitbucket") {
                "/commits/"
            } else {
                "/commit/"
            }
        return URL(string: base.absoluteString + segment + encodedCommit)
    }

    private static func stripGitSuffix(_ path: String) -> String {
        path.hasSuffix(".git") ? String(path.dropLast(4)) : path
    }

    private static func decodeFileList(_ raw: String?) -> [String] {
        guard let data = raw?.data(using: .utf8),
            let files = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return files.filter { !$0.isEmpty }
    }
}

/// Typed accessors over a decoded JSON object; absent or mistyped keys read as empty.
nonisolated private struct Reader {
    let values: [String: AnyJSONValue]

    func string(_ key: String) -> String? {
        guard let value = values[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else { return nil }
        return value
    }

    func bool(_ key: String) -> Bool {
        values[key]?.boolValue ?? false
    }

    func integer(_ key: String) -> Int64 {
        switch values[key] {
        case .number(let value): Int64(exactly: value.rounded()) ?? 0
        case .string(let value): Int64(value) ?? 0
        default: 0
        }
    }

    func stringArray(_ key: String) -> [String] {
        (values[key]?.arrayValue ?? []).compactMap { $0.stringValue }.filter { !$0.isEmpty }
    }

    func date(_ key: String) -> Date? {
        guard let raw = string(key) else { return nil }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(raw)
    }
}
