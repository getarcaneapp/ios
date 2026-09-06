import Observation
import Synchronization
import Testing
import Arcane

@testable import Arcane_Mobile

@MainActor
@Suite("Dashboard stream observation")
struct DashboardStreamStorePerformanceTests {
    @Test
    func environmentStatesInvalidateIndependently() {
        let first = DashboardStreamStore.EnvironmentState(id: "first", name: "First")
        let second = DashboardStreamStore.EnvironmentState(id: "second", name: "Second")
        let invalidationCount = Mutex(0)

        withObservationTracking {
            _ = first.hasLoaded
        } onChange: {
            invalidationCount.withLock { $0 += 1 }
        }

        second.hasLoaded = true
        #expect(invalidationCount.withLock { $0 } == 0)

        first.hasLoaded = true
        #expect(invalidationCount.withLock { $0 } == 1)
    }

    @Test
    func aggregateRequiresEveryTrackedEnvironment() {
        let first = DashboardStreamStore.EnvironmentState(id: "first", name: "First")
        let second = DashboardStreamStore.EnvironmentState(id: "second", name: "Second")
        first.snapshot = snapshot(running: 2, stopped: 1, images: 4, updates: 3)
        first.hasLoaded = true

        #expect(DashboardStreamStore.resolvedAggregate(from: [
            first.id: first,
            second.id: second,
        ]) == nil)

        second.snapshot = snapshot(running: 5, stopped: 2, images: 6, updates: 1)
        second.hasLoaded = true

        #expect(DashboardStreamStore.resolvedAggregate(from: [
            first.id: first,
            second.id: second,
        ]) == DashboardStreamStore.AggregateCounts(
            runningContainers: 7,
            stoppedContainers: 3,
            totalContainers: 10,
            totalImages: 10,
            imageUpdates: 4
        ))
    }

    private func snapshot(
        running: Int,
        stopped: Int,
        images: Int,
        updates: Int
    ) -> DashboardSnapshot {
        let pagination = PaginationResponse(
            totalPages: 1,
            totalItems: 0,
            currentPage: 1,
            itemsPerPage: 50
        )
        return DashboardSnapshot(
            containers: DashboardSnapshotContainers(
                counts: ContainerStatusCounts(
                    runningContainers: running,
                    stoppedContainers: stopped,
                    totalContainers: running + stopped
                ),
                pagination: pagination
            ),
            images: DashboardSnapshotImages(pagination: pagination),
            imageUsageCounts: ImageUsageCounts(totalImages: images),
            actionItems: ActionItems(items: [
                ActionItem(kind: .imageUpdates, count: updates, severity: .warning),
            ]),
            settings: DashboardSnapshotSettings()
        )
    }
}
