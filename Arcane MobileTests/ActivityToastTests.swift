import Arcane
import Foundation
import Testing

@testable import Arcane_Mobile

@MainActor
@Suite("Activity toast ownership", .serialized)
struct ActivityToastTests {
    @Test
    func locallyOwnedBatchDoesNotPresentDuplicateBeforeResponseOrAfterCompletion() {
        let deployments = DeploymentActivityStore()
        let presenter = ToastPresenter()
        let monitor = ActivityToastMonitor(presenter: presenter) {
            deployments.ownsActivity($0, environmentID: $1)
        }
        deployments.rememberActivityBatch("local-batch")
        defer { monitor.reset() }

        for status: ActivityStatus in [.queued, .running, .success] {
            let activity = activity(id: "local", batchID: "local-batch", status: status)
            monitor.handle(event(activity), scope: .all)
            #expect(presenter.activeToast == nil)
        }
        #expect(deployments.operation == nil)
        monitor.handle(ActivityStreamEvent(type: .snapshot, environmentID: "one",
            activities: [activity(id: "child", batchID: "local-batch", status: .running)],
            timestamp: .now), scope: .all)
        #expect(presenter.activeToast == nil)
    }

    @Test
    func unrelatedBatchesStillPresentAndUpdateInPlace() {
        let deployments = DeploymentActivityStore()
        deployments.rememberActivityBatch("local-batch")
        let presenter = ToastPresenter()
        let monitor = ActivityToastMonitor(presenter: presenter) {
            deployments.ownsActivity($0, environmentID: $1)
        }
        defer { monitor.reset() }

        var remote = activity(id: "remote", batchID: "other-batch", status: .running)
        monitor.handle(event(remote), scope: .all)
        let toastID = presenter.activeToast?.id
        #expect(presenter.activeToast?.activityID == "one#remote")
        remote.progress = 45
        monitor.handle(event(remote), scope: .all)
        #expect(presenter.activeToast?.id == toastID)
        #expect(presenter.activeToast?.activityProgress == 0.45)
        remote.status = .success
        monitor.handle(event(remote), scope: .all)
        #expect(presenter.activeToast?.activityState == .success)
        #expect(presenter.activeToast?.isPersistent == false)
    }

    @Test
    func completionDuringToastHandoffDoesNotLeaveRunningToast() async throws {
        let presenter = ToastPresenter()
        defer { presenter.dismiss() }
        presenter.show(.info("Previous feedback"))
        presenter.showActivity(id: "activity", title: "Update", progress: nil)
        presenter.finishActivity(id: "activity", title: "Update", state: .success, progress: 1)
        try await Task.sleep(for: .milliseconds(250))
        #expect(presenter.activeToast?.activityState == .success)
        #expect(presenter.activeToast?.isPersistent == false)
    }

    @Test
    func pendingProgressUpdatesPreserveToastIdentityAndLatestValue() async throws {
        let presenter = ToastPresenter()
        defer { presenter.dismiss() }
        presenter.show(.info("Previous feedback"))
        presenter.showActivity(id: "activity", title: "Update", progress: nil)
        let pendingID = presenter.currentToast?.id
        presenter.showActivity(id: "activity", title: "Update", progress: 0.45)
        #expect(presenter.activeToast == nil)
        #expect(presenter.currentToast?.id == pendingID)
        try await Task.sleep(for: .milliseconds(250))
        #expect(presenter.activeToast?.id == pendingID)
        #expect(presenter.activeToast?.activityProgress == 0.45)
    }

    @Test
    func resettingMonitorCancelsPendingActivityToast() async throws {
        let presenter = ToastPresenter()
        let monitor = ActivityToastMonitor(presenter: presenter, ownsActivity: { _, _ in false })
        presenter.show(.info("Previous feedback"))
        monitor.handle(event(activity(id: "remote", batchID: "other", status: .running)), scope: .all)
        #expect(presenter.currentToast?.activityID == "one#remote")
        monitor.reset()
        try await Task.sleep(for: .milliseconds(250))
        #expect(presenter.currentToast == nil)
    }

    @Test
    func ownershipLearnedLaterRemovesOnlyMatchingToast() {
        let presenter = ToastPresenter()
        let deployments = DeploymentActivityStore()
        let monitor = ActivityToastMonitor(presenter: presenter) {
            deployments.ownsActivity($0, environmentID: $1)
        }
        defer { monitor.reset() }
        let local = activity(id: "local", batchID: "local-batch", status: .running)
        monitor.handle(event(local), scope: .all)
        #expect(presenter.activeToast?.activityID == "one#local")
        deployments.rememberActivityBatch("local-batch")
        monitor.handle(event(local), scope: .all)
        #expect(presenter.currentToast == nil)
        let remote = activity(id: "remote", batchID: "other-batch", status: .running)
        monitor.handle(event(remote), scope: .all)
        monitor.handle(event(local), scope: .all)
        #expect(presenter.currentToast?.activityID == "one#remote")
    }

    private func activity(id: String, batchID: String, status: ActivityStatus) -> Activity {
        Activity(id: id, environmentID: "one", batchID: batchID, type: .autoUpdate,
                 status: status, startedBy: .init(userId: "user", username: "User"),
                 startedAt: .now, createdAt: .now)
    }

    private func event(_ activity: Activity) -> ActivityStreamEvent {
        ActivityStreamEvent(type: .activity, environmentID: "one", activity: activity, timestamp: .now)
    }
}
