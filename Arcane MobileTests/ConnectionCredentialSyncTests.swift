import Foundation
import Security
import Testing

@testable import Arcane_Mobile

@Suite("Connection credential sync")
struct ConnectionCredentialSyncTests {
    @Test
    func credentialIsReleasedOnlyForItsExactProfileAndOrigin() throws {
        let profileID = UUID()
        let profile = ConnectionProfile(
            id: profileID,
            name: "Home",
            serverURL: "https://home.example.com",
            modifiedAt: .now
        )
        let record = try ConnectionCredentialRecord(
            profile: profile,
            username: "admin",
            password: "test-password"
        )

        #expect(record.credential(for: profile)?.username == "admin")
        #expect(record.credential(for: profile)?.password == "test-password")

        let differentProfile = ConnectionProfile(
            id: UUID(),
            name: profile.name,
            serverURL: profile.serverURL,
            modifiedAt: profile.modifiedAt
        )
        #expect(record.credential(for: differentProfile) == nil)

        let changedOrigin = ConnectionProfile(
            id: profile.id,
            name: profile.name,
            serverURL: "https://other.example.com",
            modifiedAt: profile.modifiedAt
        )
        #expect(record.credential(for: changedOrigin) == nil)
    }

    @Test
    func emptyAndOversizedCredentialsAreRejected() {
        let profile = ConnectionProfile(
            id: UUID(),
            name: "Home",
            serverURL: "https://home.example.com",
            modifiedAt: .now
        )

        #expect(throws: ConnectionCredentialValidationError.self) {
            try ConnectionCredentialRecord(profile: profile, username: "", password: "password")
        }
        #expect(throws: ConnectionCredentialValidationError.self) {
            try ConnectionCredentialRecord(profile: profile, username: "admin", password: "")
        }
        #expect(throws: ConnectionCredentialValidationError.self) {
            try ConnectionCredentialRecord(
                profile: profile,
                username: "admin",
                password: String(repeating: "x", count: 16_385)
            )
        }
    }

    @Test
    func optionalProfileSignInRequiresEitherBothFieldsOrNeither() throws {
        let connectionOnly = try SyncedConnectionCredential.optional(username: "", password: "")
        #expect(connectionOnly == nil)

        #expect(throws: ConnectionCredentialValidationError.emptyUsername) {
            try SyncedConnectionCredential.optional(username: "", password: "password")
        }
        #expect(throws: ConnectionCredentialValidationError.emptyPassword) {
            try SyncedConnectionCredential.optional(username: "admin", password: "")
        }

        let credential = try #require(
            try SyncedConnectionCredential.optional(
                username: "admin",
                password: "super-secret-value"
            )
        )
        #expect(credential.username == "admin")
        #expect(credential.password == "super-secret-value")
        #expect(!String(describing: credential).contains("admin"))
        #expect(!String(reflecting: credential).contains("super-secret-value"))
    }

    @Test
    func keychainPolicyIsSynchronizableUnlockedAndAppPrivate() throws {
        let store = ConnectionCredentialKeychainStore(service: "test.connection.credentials")
        let profileID = UUID()
        let query = store.itemQuery(profileID: profileID)
        let attributes = store.newItemAttributes(data: Data("secret".utf8))

        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "test.connection.credentials")
        #expect(query[kSecAttrAccount as String] as? String == profileID.uuidString)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == true)
        #expect(
            query[kSecAttrAccessGroup as String] as? String
                == SharedKeychain.appAccessGroup
        )
        #expect(
            query[kSecAttrAccessGroup as String] as? String
                != SharedKeychain.accessGroup
        )
        #expect(
            attributes[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleWhenUnlocked as String
        )
    }

    @Test
    func encodedCredentialRoundTripsWithoutChangingSecretBytes() throws {
        let profile = ConnectionProfile(
            id: UUID(),
            name: "Home",
            serverURL: "https://home.example.com",
            modifiedAt: .now
        )
        let record = try ConnectionCredentialRecord(
            profile: profile,
            username: " admin@example.com ",
            password: "  exact password\n"
        )

        let encoded = try ConnectionCredentialKeychainStore.encode(record)
        let decoded = try ConnectionCredentialKeychainStore.decode(encoded)

        #expect(decoded == record)
        #expect(!String(describing: record).contains("admin@example.com"))
        #expect(!String(describing: record).contains("exact password"))
        #expect(!String(reflecting: record).contains("exact password"))
    }
}
