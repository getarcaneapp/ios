import Arcane
import Foundation
import Testing

@testable import Arcane_Mobile

@MainActor
@Suite("Image update count synchronization")
struct ImageUpdateCountSynchronizationTests {
    @Test
    func freshSharedZeroOverridesStaleDashboardCounts() {
        #expect(
            DashboardImageUpdateCountResolver.resolve(
                shared: 0,
                streamed: 4,
                supplemental: 4
            ) == 0
        )
    }

    @Test
    func refreshedEnvironmentCountUpdatesTheFleetTotal() throws {
        let store = ImageUpdateCountStore()
        let client = ArcaneClient(
            configuration: .init(
                baseURL: try #require(URL(string: "https://arcane.example"))
            )
        )

        store.setSummaryCounts(
            ["one": 2, "two": 3],
            client: client,
            userID: "user"
        )
        #expect(
            store.total(
                client: client,
                userID: "user",
                environmentIDs: [
                    EnvironmentID(rawValue: "one"),
                    EnvironmentID(rawValue: "two"),
                ]
            ) == nil
        )

        store.setCount(
            0,
            environmentID: EnvironmentID(rawValue: "one"),
            client: client,
            userID: "user"
        )

        #expect(
            store.total(
                client: client,
                userID: "user",
                environmentIDs: [
                    EnvironmentID(rawValue: "one"),
                    EnvironmentID(rawValue: "two"),
                ]
            ) == 3
        )
    }
}
