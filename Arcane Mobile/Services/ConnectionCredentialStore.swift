import Foundation
import Security

nonisolated struct SyncedConnectionCredential: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let username: String
    let password: String

    init(username: String, password: String) throws {
        guard !username.isEmpty else {
            throw ConnectionCredentialValidationError.emptyUsername
        }
        guard !password.isEmpty else {
            throw ConnectionCredentialValidationError.emptyPassword
        }
        guard username.utf8.count <= ConnectionCredentialRecord.maximumUsernameBytes,
              password.utf8.count <= ConnectionCredentialRecord.maximumPasswordBytes else {
            throw ConnectionCredentialValidationError.credentialTooLarge
        }

        self.username = username
        self.password = password
    }

    /// Empty fields represent a connection-only profile. A partially entered
    /// sign-in is rejected so saving a profile never silently drops a secret.
    static func optional(username: String, password: String) throws -> Self? {
        if username.isEmpty, password.isEmpty {
            return nil
        }
        return try Self(username: username, password: password)
    }

    var description: String {
        "SyncedConnectionCredential(username: <redacted>, password: <redacted>)"
    }

    var debugDescription: String { description }
}

nonisolated enum ConnectionCredentialValidationError: LocalizedError, Equatable, Sendable {
    case emptyUsername
    case emptyPassword
    case credentialTooLarge
    case invalidProfile
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .emptyUsername:
            return "Enter a username or clear both sign-in fields."
        case .emptyPassword:
            return "Enter a password or clear both sign-in fields."
        case .credentialTooLarge:
            return "The username or password is too large to sync."
        case .invalidProfile:
            return "The connection profile isn't valid for credential sync."
        case .persistenceFailed:
            return "The sign-in couldn't be updated in iCloud Keychain."
        }
    }
}

nonisolated struct ConnectionCredentialRecord: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    static let schemaVersion = 1
    static let maximumUsernameBytes = 1_024
    static let maximumPasswordBytes = 16_384

    let version: Int
    let profileID: UUID
    let serverURL: String
    let username: String
    let password: String

    init(profile: ConnectionProfile, username: String, password: String) throws {
        let credential = try SyncedConnectionCredential(username: username, password: password)
        guard let normalizedServerURL = try? ConnectionProfileSync.normalizedServerURL(profile.serverURL) else {
            throw ConnectionCredentialValidationError.invalidProfile
        }

        version = Self.schemaVersion
        profileID = profile.id
        serverURL = normalizedServerURL
        self.username = credential.username
        self.password = credential.password
    }

    func credential(for profile: ConnectionProfile) -> SyncedConnectionCredential? {
        guard version == Self.schemaVersion,
              profileID == profile.id,
              let normalizedServerURL = try? ConnectionProfileSync.normalizedServerURL(profile.serverURL),
              serverURL == normalizedServerURL else {
            return nil
        }
        return try? SyncedConnectionCredential(username: username, password: password)
    }

    var description: String {
        "ConnectionCredentialRecord(profileID: \(profileID), credentials: <redacted>)"
    }

    var debugDescription: String { description }
}

nonisolated struct ConnectionCredentialKeychainStore {
    static let defaultService = "com.getarcaneapp.ios.mobile.connection-credential.v1"

    let service: String

    init(service: String = Self.defaultService) {
        self.service = service
    }

    func itemQuery(profileID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecAttrAccessGroup as String: SharedKeychain.appAccessGroup,
            kSecAttrSynchronizable as String: true,
        ]
    }

    func newItemAttributes(data: Data) -> [String: Any] {
        [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
    }

    func load(profileID: UUID) throws -> ConnectionCredentialRecord? {
        var query = itemQuery(profileID: profileID)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status == errSecSuccess ? errSecDecode : status)
        }

        let record = try Self.decode(data)
        guard record.profileID == profileID else {
            throw KeychainError(status: errSecDecode)
        }
        return record
    }

    func profileIDs() throws -> Set<UUID> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: SharedKeychain.appAccessGroup,
            kSecAttrSynchronizable as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
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

        return Set(items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String else { return nil }
            return UUID(uuidString: account)
        })
    }

    func save(_ record: ConnectionCredentialRecord) throws {
        let data = try Self.encode(record)
        let query = itemQuery(profileID: record.profileID)
        let attributes = newItemAttributes(data: data)

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(status: updateStatus)
        }

        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard retryStatus == errSecSuccess else {
                throw KeychainError(status: retryStatus)
            }
            return
        }
        guard addStatus == errSecSuccess else {
            throw KeychainError(status: addStatus)
        }
    }

    func delete(profileID: UUID) throws {
        let status = SecItemDelete(itemQuery(profileID: profileID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    static func encode(_ record: ConnectionCredentialRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record)
    }

    static func decode(_ data: Data) throws -> ConnectionCredentialRecord {
        let record = try JSONDecoder().decode(ConnectionCredentialRecord.self, from: data)
        guard record.version == ConnectionCredentialRecord.schemaVersion,
              !record.username.isEmpty,
              !record.password.isEmpty,
              record.username.utf8.count <= ConnectionCredentialRecord.maximumUsernameBytes,
              record.password.utf8.count <= ConnectionCredentialRecord.maximumPasswordBytes,
              let normalizedServerURL = try? ConnectionProfileSync.normalizedServerURL(record.serverURL),
              normalizedServerURL == record.serverURL else {
            throw KeychainError(status: errSecDecode)
        }
        return record
    }

    private struct KeychainError: Error {
        let status: OSStatus
    }
}
