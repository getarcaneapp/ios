import Arcane
import Foundation
import Testing

@testable import Arcane_Mobile

@Suite("Activity state synchronization")
struct ActivityStateSynchronizationTests {
    @Test
    func allActivitiesPresentsRunningInitialSnapshotItems() {
        #expect(
            ActivityToastInitialSnapshotPolicy.shouldPresent(
                status: .running,
                scope: .all
            )
        )
        #expect(
            ActivityToastInitialSnapshotPolicy.shouldPresent(
                status: .queued,
                scope: .all
            )
        )
        #expect(
            !ActivityToastInitialSnapshotPolicy.shouldPresent(
                status: .running,
                scope: .userInitiated
            )
        )
        #expect(
            !ActivityToastInitialSnapshotPolicy.shouldPresent(
                status: .success,
                scope: .all
            )
        )
    }

    @Test
    func clearingHistoryRemovesOnlyTerminalItemsInClearedEnvironments() {
        let activities = [
            activity(id: "failed-cleared", environmentID: "one", status: .failed),
            activity(id: "success-cleared", environmentID: "one", status: .success),
            activity(id: "running-preserved", environmentID: "one", status: .running),
            activity(id: "failed-other", environmentID: "two", status: .failed),
        ]

        let retained = ActivityHistoryClearFilter.retainingActiveActivities(
            in: activities,
            clearedEnvironmentIDs: ["one"]
        )

        #expect(Set(retained.map(\.id)) == ["running-preserved", "failed-other"])
    }

    private func activity(
        id: String,
        environmentID: String,
        status: ActivityStatus
    ) -> Activity {
        Activity(
            id: id,
            environmentID: environmentID,
            sourceEnvironmentID: environmentID,
            type: .autoUpdate,
            status: status,
            startedAt: .distantPast,
            createdAt: .distantPast
        )
    }
}
