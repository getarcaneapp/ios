import Foundation
import Testing

@testable import Arcane_Mobile

@Suite
struct ConnectionProfileSyncTests {
    @Test
    func normalizationProducesSafeCanonicalServerURLs() throws {
        #expect(
            try ConnectionProfileSync.normalizedServerURL(
                "  HTTPS://admin:secret@Example.COM:443/arcane/?token=private#section  "
            ) == "https://example.com/arcane"
        )
        #expect(
            try ConnectionProfileSync.normalizedServerURL("http://192.168.1.20:3000/")
                == "http://192.168.1.20:3000"
        )
        #expect(
            try ConnectionProfileSync.normalizedServerURL("arcane.example.com")
                == "https://arcane.example.com"
        )
        #expect(throws: ConnectionProfileValidationError.unsupportedScheme) {
            try ConnectionProfileSync.normalizedServerURL("ftp://arcane.example.com")
        }
    }

    @Test
    func mergeKeepsIndependentEditsAndNewestRevision() throws {
        let sharedID = UUID()
        let localOnlyID = UUID()
        let remoteOnlyID = UUID()
        let local = payload([
            record(
                id: sharedID,
                name: "Old Name",
                url: "https://one.example.com",
                timestamp: 10,
                revision: "a"
            ),
            record(
                id: localOnlyID,
                name: "Local",
                url: "https://local.example.com",
                timestamp: 20,
                revision: "a"
            ),
        ])
        let remote = payload([
            record(
                id: sharedID,
                name: "New Name",
                url: "https://one.example.com",
                timestamp: 30,
                revision: "b"
            ),
            record(
                id: remoteOnlyID,
                name: "Remote",
                url: "https://remote.example.com",
                timestamp: 20,
                revision: "b"
            ),
        ])

        let merged = ConnectionProfileSync.merge(local, remote)
        let profiles = ConnectionProfileSync.activeProfiles(in: merged)

        #expect(profiles.count == 3)
        #expect(profiles.first(where: { $0.id == sharedID })?.name == "New Name")
        #expect(profiles.contains(where: { $0.id == localOnlyID }))
        #expect(profiles.contains(where: { $0.id == remoteOnlyID }))
    }

    @Test
    func deletionTombstoneWinsAndPreventsProfileRestoration() {
        let id = UUID()
        let active = record(
            id: id,
            name: "Home",
            url: "https://home.example.com",
            timestamp: 10,
            revision: "a"
        )
        let deleted = record(
            id: id,
            name: "Home",
            url: "https://home.example.com",
            timestamp: 20,
            revision: "b",
            isDeleted: true
        )

        let merged = ConnectionProfileSync.merge(payload([active]), payload([deleted]))
        let mergedAgain = ConnectionProfileSync.merge(merged, payload([active]))

        #expect(ConnectionProfileSync.activeProfiles(in: merged).isEmpty)
        #expect(ConnectionProfileSync.activeProfiles(in: mergedAgain).isEmpty)
    }

    @Test
    func concurrentDuplicateServersCollapseToOneProfile() {
        let older = record(
            id: UUID(),
            name: "Old Home",
            url: "https://HOME.example.com/",
            timestamp: 10,
            revision: "a"
        )
        let newer = record(
            id: UUID(),
            name: "Home",
            url: "https://home.example.com",
            timestamp: 20,
            revision: "b"
        )

        let merged = ConnectionProfileSync.merge(payload([older]), payload([newer]))
        let profiles = ConnectionProfileSync.activeProfiles(in: merged)

        #expect(profiles.count == 1)
        #expect(profiles.first?.id == newer.id)
        #expect(merged.records.first(where: { $0.id == older.id })?.isDeleted == true)
    }

    @Test
    func mergeSanitizesNamesAndBoundsConcurrentProfiles() {
        let records = (0..<30).map { index in
            record(
                id: UUID(),
                name: index == 29 ? "  Home\nServer  " : "Server \(index)",
                url: "https://server-\(index).example.com",
                timestamp: TimeInterval(index),
                revision: "r\(index)"
            )
        }

        let merged = ConnectionProfileSync.merge(payload(records), .empty)
        let profiles = ConnectionProfileSync.activeProfiles(in: merged)

        #expect(profiles.count == ConnectionProfileSync.maximumActiveProfiles)
        #expect(profiles.contains(where: { $0.name == "Home Server" }))
        #expect(merged.records.filter(\.isDeleted).count == 5)
    }

    private func payload(_ records: [ConnectionProfileRecord]) -> ConnectionProfilePayload {
        ConnectionProfilePayload(version: 1, records: records)
    }

    private func record(
        id: UUID,
        name: String,
        url: String,
        timestamp: TimeInterval,
        revision: String,
        isDeleted: Bool = false
    ) -> ConnectionProfileRecord {
        ConnectionProfileRecord(
            id: id,
            name: name,
            serverURL: url,
            modifiedAt: Date(timeIntervalSince1970: timestamp),
            revision: revision,
            isDeleted: isDeleted
        )
    }
}
