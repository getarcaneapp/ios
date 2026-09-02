import Foundation
import Observation
import Security

nonisolated struct ConnectionProfile: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let serverURL: String
    let modifiedAt: Date
}

nonisolated enum ConnectionProfileValidationError: LocalizedError, Equatable, Sendable {
    case invalidServerURL
    case unsupportedScheme
    case profileLimitReached
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "Enter a valid Arcane server address."
        case .unsupportedScheme:
            return "Connection profiles support HTTP and HTTPS server addresses."
        case .profileLimitReached:
            return "You can save up to 25 connection profiles."
        case .persistenceFailed:
            return "The connection profile couldn't be saved."
        }
    }
}

nonisolated struct ConnectionProfileRecord: Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var serverURL: String
    var modifiedAt: Date
    var revision: String
    var isDeleted: Bool

    var profile: ConnectionProfile? {
        guard !isDeleted else { return nil }
        return ConnectionProfile(
            id: id,
            name: name,
            serverURL: serverURL,
            modifiedAt: modifiedAt
        )
    }
}

nonisolated struct ConnectionProfilePayload: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var version: Int
    var records: [ConnectionProfileRecord]

    static let empty = ConnectionProfilePayload(version: schemaVersion, records: [])
}

/// Pure profile validation and merge rules shared by local storage and iCloud.
/// Records are merged independently so concurrent edits on different devices do
/// not replace unrelated profiles. Deleted records remain as tombstones to keep
/// an offline device from restoring a profile after it reconnects.
nonisolated enum ConnectionProfileSync {
    static let maximumActiveProfiles = 25

    static func normalizedServerURL(_ rawValue: String) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2_048 else {
            throw ConnectionProfileValidationError.invalidServerURL
        }

        if let schemeSeparator = trimmed.range(of: "://") {
            let scheme = trimmed[..<schemeSeparator.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else {
                throw ConnectionProfileValidationError.unsupportedScheme
            }
        }

        let value = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            throw ConnectionProfileValidationError.invalidServerURL
        }

        components.scheme = scheme
        components.host = host.lowercased()
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil

        if (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80) {
            components.port = nil
        }

        while components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        if components.path == "/" {
            components.path = ""
        }

        guard let url = components.url, url.host() != nil else {
            throw ConnectionProfileValidationError.invalidServerURL
        }
        return url.absoluteString
    }

    static func defaultName(for serverURL: String) -> String {
        guard let url = URL(string: serverURL), let host = url.host() else {
            return "Arcane Server"
        }
        if let port = url.port {
            return "\(host):\(port)"
        }
        return host
    }

    static func sanitizedName(_ rawValue: String, serverURL: String) -> String {
        let prepared = rawValue.unicodeScalars.reduce(into: "") { result, scalar in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                result.append(" ")
            } else if !CharacterSet.controlCharacters.contains(scalar) {
                result.unicodeScalars.append(scalar)
            }
        }
        let collapsed = prepared
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let fallback = defaultName(for: serverURL)
        return String((collapsed.isEmpty ? fallback : collapsed).prefix(60))
    }

    static func merge(
        _ local: ConnectionProfilePayload,
        _ remote: ConnectionProfilePayload
    ) -> ConnectionProfilePayload {
        var recordsByID: [UUID: ConnectionProfileRecord] = [:]
        for record in local.records + remote.records {
            if let existing = recordsByID[record.id] {
                recordsByID[record.id] = preferred(existing, record)
            } else {
                recordsByID[record.id] = record
            }
        }

        // Canonicalize old payloads and retire malformed records without ever
        // exposing or re-uploading unsafe URL components.
        for (id, record) in recordsByID where !record.isDeleted {
            guard let normalized = try? normalizedServerURL(record.serverURL) else {
                var tombstone = record
                tombstone.isDeleted = true
                recordsByID[id] = tombstone
                continue
            }
            let safeName = sanitizedName(record.name, serverURL: normalized)
            if normalized != record.serverURL || safeName != record.name {
                var canonical = record
                canonical.name = safeName
                canonical.serverURL = normalized
                recordsByID[id] = canonical
            }
        }

        // Two offline devices can independently add the same server with
        // different IDs. Keep the newest one and tombstone its duplicate so it
        // cannot reappear when an older payload arrives later.
        let activeRecords = recordsByID.values
            .filter { !$0.isDeleted }
            .sorted { isNewer($0, than: $1) }
        var winnerByURL: [String: ConnectionProfileRecord] = [:]
        for record in activeRecords {
            if let winner = winnerByURL[record.serverURL] {
                var tombstone = record
                tombstone.modifiedAt = winner.modifiedAt
                tombstone.revision = winner.revision
                tombstone.isDeleted = true
                recordsByID[record.id] = tombstone
            } else {
                winnerByURL[record.serverURL] = record
            }
        }

        let retainedActiveRecords = recordsByID.values
            .filter { !$0.isDeleted }
            .sorted { isNewer($0, than: $1) }
        for record in retainedActiveRecords.dropFirst(maximumActiveProfiles) {
            var tombstone = record
            tombstone.isDeleted = true
            recordsByID[record.id] = tombstone
        }

        return ConnectionProfilePayload(
            version: max(
                max(local.version, remote.version),
                ConnectionProfilePayload.schemaVersion
            ),
            records: recordsByID.values.sorted { $0.id.uuidString < $1.id.uuidString }
        )
    }

    static func activeProfiles(in payload: ConnectionProfilePayload) -> [ConnectionProfile] {
        payload.records
            .compactMap(\.profile)
            .sorted {
                let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
                if comparison == .orderedSame {
                    return $0.serverURL.localizedCaseInsensitiveCompare($1.serverURL) == .orderedAscending
                }
                return comparison == .orderedAscending
            }
    }

    private static func preferred(
        _ lhs: ConnectionProfileRecord,
        _ rhs: ConnectionProfileRecord
    ) -> ConnectionProfileRecord {
        if isNewer(lhs, than: rhs) { return lhs }
        if isNewer(rhs, than: lhs) { return rhs }
        if lhs.isDeleted != rhs.isDeleted { return lhs.isDeleted ? lhs : rhs }
        return lhs.id.uuidString <= rhs.id.uuidString ? lhs : rhs
    }

    private static func isNewer(
        _ lhs: ConnectionProfileRecord,
        than rhs: ConnectionProfileRecord
    ) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt {
            return lhs.modifiedAt > rhs.modifiedAt
        }
        if lhs.revision != rhs.revision {
            return lhs.revision > rhs.revision
        }
        return lhs.id.uuidString > rhs.id.uuidString
    }
}

/// Stores each profile record as a synchronizable generic-password item. The
/// value contains only the already-sanitized profile metadata.
nonisolated struct ConnectionProfileKeychainStore {
    private static let service = "com.getarcaneapp.ios.mobile.connection-profile.v1"

    func load() throws -> ConnectionProfilePayload {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccessGroup as String: SharedKeychain.accessGroup,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: kCFBooleanTrue as Any,
            kSecReturnData as String: kCFBooleanTrue as Any,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return .empty
        }
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }

        let items: [[String: Any]]
        if let matches = result as? [[String: Any]] {
            items = matches
        } else if let match = result as? [String: Any] {
            items = [match]
        } else {
            throw KeychainError(status: errSecDecode)
        }

        let records = items.compactMap { item -> ConnectionProfileRecord? in
            guard let data = item[kSecValueData as String] as? Data,
                  let account = item[kSecAttrAccount as String] as? String,
                  let record = Self.decode(data),
                  record.id.uuidString == account else {
                return nil
            }
            return record
        }
        return ConnectionProfilePayload(
            version: ConnectionProfilePayload.schemaVersion,
            records: records
        )
    }

    func save(_ payload: ConnectionProfilePayload) throws {
        for record in payload.records {
            guard let data = Self.encode(record) else {
                throw KeychainError(status: errSecParam)
            }
            try upsert(data: data, account: record.id.uuidString)
        }
    }

    private func upsert(data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: SharedKeychain.accessGroup,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(status: updateStatus)
        }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard retryStatus == errSecSuccess else {
                throw KeychainError(status: retryStatus)
            }
            return
        }
        guard addStatus == errSecSuccess else {
            throw KeychainError(status: addStatus)
        }
    }

    private static func encode(_ record: ConnectionProfileRecord) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(record)
    }

    private static func decode(_ data: Data) -> ConnectionProfileRecord? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(ConnectionProfileRecord.self, from: data)
    }

    private struct KeychainError: Error {
        let status: OSStatus
    }
}

@MainActor
@Observable
final class ConnectionProfileStore {
    enum SyncState: Equatable {
        case iCloudKeychain
        case unavailable

        var description: String {
            switch self {
            case .iCloudKeychain:
                return "Syncs with iCloud Keychain"
            case .unavailable:
                return "iCloud Keychain is temporarily unavailable"
            }
        }
    }

    private let keychainStore: ConnectionProfileKeychainStore
    private let credentialStore: ConnectionCredentialKeychainStore
    private var payload: ConnectionProfilePayload = .empty

    private(set) var profiles: [ConnectionProfile] = []
    private(set) var syncedCredentialProfileIDs: Set<UUID> = []
    private(set) var syncState: SyncState = .unavailable

    init(
        keychainStore: ConnectionProfileKeychainStore = ConnectionProfileKeychainStore(),
        credentialStore: ConnectionCredentialKeychainStore = ConnectionCredentialKeychainStore()
    ) {
        self.keychainStore = keychainStore
        self.credentialStore = credentialStore
        refreshFromICloud()
    }

    func profile(matching serverURL: String) -> ConnectionProfile? {
        guard let normalized = try? ConnectionProfileSync.normalizedServerURL(serverURL) else {
            return nil
        }
        return profiles.first { $0.serverURL == normalized }
    }

    @discardableResult
    func saveConnectedServer(_ serverURL: String) throws -> ConnectionProfile {
        let normalized = try ConnectionProfileSync.normalizedServerURL(serverURL)
        if let existing = profiles.first(where: { $0.serverURL == normalized }) {
            return existing
        }
        return try save(name: ConnectionProfileSync.defaultName(for: normalized), serverURL: normalized)
    }

    @discardableResult
    func save(name: String, serverURL: String) throws -> ConnectionProfile {
        try write(profileID: nil, name: name, serverURL: serverURL)
    }

    /// Saves the metadata and optional password sign-in as one app-level
    /// connection profile. The two records remain separate in Keychain so the
    /// widget-readable profile metadata never grants access to credentials.
    @discardableResult
    func saveConnectionProfile(
        _ profile: ConnectionProfile?,
        name: String,
        serverURL: String,
        credential: SyncedConnectionCredential?
    ) throws -> ConnectionProfile {
        let savedProfile: ConnectionProfile
        if let profile {
            savedProfile = try update(profile, name: name, serverURL: serverURL)
        } else {
            savedProfile = try save(name: name, serverURL: serverURL)
        }

        if let credential {
            try saveSyncedCredential(
                for: savedProfile,
                username: credential.username,
                password: credential.password
            )
        } else if hasSyncedCredential(for: savedProfile) {
            try removeSyncedCredential(for: savedProfile)
        }
        return savedProfile
    }

    /// A successful local login belongs to its connection profile, so update
    /// both together instead of maintaining a separate login-screen setting.
    @discardableResult
    func saveConnectedServer(
        _ serverURL: String,
        credential: SyncedConnectionCredential
    ) throws -> ConnectionProfile {
        let profile = try saveConnectedServer(serverURL)
        try saveSyncedCredential(
            for: profile,
            username: credential.username,
            password: credential.password
        )
        return profile
    }

    @discardableResult
    func update(_ profile: ConnectionProfile, name: String, serverURL: String) throws -> ConnectionProfile {
        let normalized = try ConnectionProfileSync.normalizedServerURL(serverURL)
        if normalized != profile.serverURL {
            try removeSyncedCredential(for: profile)
        }
        return try write(profileID: profile.id, name: name, serverURL: serverURL)
    }

    func delete(_ profile: ConnectionProfile) throws {
        try removeSyncedCredential(for: profile)
        mergeLatestKeychainPayload()
        guard let index = payload.records.firstIndex(where: { $0.id == profile.id }) else { return }
        var candidate = payload
        candidate.records[index].modifiedAt = .now
        candidate.records[index].revision = UUID().uuidString
        candidate.records[index].isDeleted = true
        try commit(candidate)
    }

    func hasSyncedCredential(for profile: ConnectionProfile) -> Bool {
        syncedCredentialProfileIDs.contains(profile.id)
    }

    func syncedCredential(for profile: ConnectionProfile) throws -> SyncedConnectionCredential? {
        do {
            guard let record = try credentialStore.load(profileID: profile.id) else {
                syncedCredentialProfileIDs.remove(profile.id)
                return nil
            }
            guard let credential = record.credential(for: profile) else {
                try credentialStore.delete(profileID: profile.id)
                syncedCredentialProfileIDs.remove(profile.id)
                return nil
            }
            syncedCredentialProfileIDs.insert(profile.id)
            return credential
        } catch {
            syncState = .unavailable
            throw ConnectionCredentialValidationError.persistenceFailed
        }
    }

    func saveSyncedCredential(
        for profile: ConnectionProfile,
        username: String,
        password: String
    ) throws {
        let record = try ConnectionCredentialRecord(
            profile: profile,
            username: username,
            password: password
        )
        do {
            try credentialStore.save(record)
        } catch {
            syncState = .unavailable
            throw ConnectionCredentialValidationError.persistenceFailed
        }
        syncedCredentialProfileIDs.insert(profile.id)
        syncState = .iCloudKeychain
    }

    func removeSyncedCredential(for profile: ConnectionProfile) throws {
        do {
            try credentialStore.delete(profileID: profile.id)
        } catch {
            syncState = .unavailable
            throw ConnectionCredentialValidationError.persistenceFailed
        }
        syncedCredentialProfileIDs.remove(profile.id)
    }

    /// Synchronizable keychain items do not emit an app-level change
    /// notification. Refresh when the app becomes active to pick up changes
    /// made on another device.
    func refreshFromICloud() {
        do {
            let remote = try keychainStore.load()
            let merged = ConnectionProfileSync.merge(payload, remote)
            if merged != remote {
                try keychainStore.save(merged)
            }
            payload = merged
            publishProfiles()
            try refreshCredentialProfileIDs()
            syncState = .iCloudKeychain
        } catch {
            syncState = .unavailable
        }
    }

    private func write(
        profileID: UUID?,
        name: String,
        serverURL: String
    ) throws -> ConnectionProfile {
        mergeLatestKeychainPayload()
        let normalized = try ConnectionProfileSync.normalizedServerURL(serverURL)
        let existingByURL = profiles.first { $0.serverURL == normalized }
        let id = profileID ?? existingByURL?.id ?? UUID()

        if existingByURL == nil,
           profileID == nil,
           profiles.count >= ConnectionProfileSync.maximumActiveProfiles {
            throw ConnectionProfileValidationError.profileLimitReached
        }

        var candidate = payload
        let record = ConnectionProfileRecord(
            id: id,
            name: ConnectionProfileSync.sanitizedName(name, serverURL: normalized),
            serverURL: normalized,
            modifiedAt: .now,
            revision: UUID().uuidString,
            isDeleted: false
        )
        if let index = candidate.records.firstIndex(where: { $0.id == id }) {
            candidate.records[index] = record
        } else {
            candidate.records.append(record)
        }

        try commit(candidate)
        guard let saved = profiles.first(where: { $0.id == id })
            ?? profiles.first(where: { $0.serverURL == normalized }) else {
            throw ConnectionProfileValidationError.persistenceFailed
        }
        return saved
    }

    private func mergeLatestKeychainPayload() {
        do {
            payload = ConnectionProfileSync.merge(payload, try keychainStore.load())
            publishProfiles()
            try refreshCredentialProfileIDs()
            syncState = .iCloudKeychain
        } catch {
            syncState = .unavailable
        }
    }

    private func commit(_ candidate: ConnectionProfilePayload) throws {
        let normalized = ConnectionProfileSync.merge(candidate, .empty)
        do {
            try keychainStore.save(normalized)
        } catch {
            syncState = .unavailable
            throw ConnectionProfileValidationError.persistenceFailed
        }
        payload = normalized
        publishProfiles()
        syncState = .iCloudKeychain
    }

    private func publishProfiles() {
        profiles = ConnectionProfileSync.activeProfiles(in: payload)
    }

    private func refreshCredentialProfileIDs() throws {
        let storedProfileIDs = try credentialStore.profileIDs()
        var validProfileIDs: Set<UUID> = []

        for profile in profiles where storedProfileIDs.contains(profile.id) {
            guard let record = try credentialStore.load(profileID: profile.id),
                  record.credential(for: profile) != nil else {
                try credentialStore.delete(profileID: profile.id)
                continue
            }
            validProfileIDs.insert(profile.id)
        }

        syncedCredentialProfileIDs = validProfileIDs
    }
}
