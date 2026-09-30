import Arcane
import Foundation
import Testing

@testable import Arcane_Mobile

@Suite("Activity state synchronization")
struct ActivityStateSynchronizationTests {
    @Test
    func progressPreservesMeasuredValuesAndLeavesUnmeasuredWorkIndeterminate() {
        var running = activity(id: "running", environmentID: "one", status: .running)
        #expect(running.displayProgress == nil)
        running.progress = 45
        #expect(running.displayProgress == 45)
        running.progress = -5
        #expect(running.displayProgress == 0)
        running.progress = 150
        #expect(running.displayProgress == 100)
        running.status = .failed
        running.progress = 45
        #expect(running.displayProgress == 45)
        running.progress = nil
        #expect(running.displayProgress == nil)
        running.status = .success
        #expect(running.displayProgress == 100)
    }

    @Test
    func batchProgressRequiresMeasuredProgressForEveryUnfinishedMember() {
        let completed = activity(id: "done", environmentID: "one", status: .success)
        var running = activity(id: "running", environmentID: "one", status: .running)
        #expect(ActivityBatchSummary(id: "batch", activities: [completed, running]).progress == nil)
        running.progress = 40
        #expect(ActivityBatchSummary(id: "batch", activities: [completed, running]).progress == 70)
        running.status = .failed
        #expect(ActivityBatchSummary(id: "batch", activities: [completed, running]).progress == 70)
    }

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
