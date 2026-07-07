//
//  DeployLiveActivityController.swift
//  Arcane Mobile
//
//  Owns the single deploy/pull Live Activity for the active operation.
//  Updates flow while the app process runs: the foreground, plus the ~30s
//  background grace period `DeploymentActivityStore` buys with a background
//  task. If the app suspends mid-operation, `staleDate` dims the presentation;
//  on resume the store re-attaches to the backing server activity and this
//  controller catches the Live Activity up to the server's state. Updating
//  *while* suspended would require APNs (ActivityKit push tokens + a push
//  relay for self-hosted servers) — a possible future step.
//
//  Updates are throttled: immediate on phase/terminal changes, otherwise
//  coalesced latest-wins to ≤1/sec (same shape as WidgetSnapshotPublisher) so
//  per-NDJSON-line churn never hits ActivityKit.
//
//  Concurrency: `Activity` is not Sendable, so it never touches main-actor
//  state. A single detached pump task requests the activity and owns it for
//  its whole lifetime; the main-actor side only yields Sendable commands into
//  an AsyncStream.
//

import ActivityKit
import Foundation

@MainActor
final class DeployLiveActivityController {
    private enum Command: Sendable {
        case update(DeployActivityAttributes.ContentState, staleDate: Date)
        case end(DeployActivityAttributes.ContentState, linger: TimeInterval)
        case endImmediately
    }

    /// Non-nil while a Live Activity pump is alive.
    private var commands: AsyncStream<Command>.Continuation?
    private var pumpTask: Task<Void, Never>?
    private var pendingState: DeployActivityAttributes.ContentState?
    private var flushTask: Task<Void, Never>?
    private var lastFlush: Date = .distantPast

    nonisolated private static let minUpdateInterval: TimeInterval = 1
    nonisolated private static let staleGrace: TimeInterval = 60

    func start(for operation: DeploymentOperation) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        endCurrent()

        let attributes = DeployActivityAttributes(
            targetName: operation.targetName,
            actionKind: operation.kind.rawValue,
            environmentName: operation.environmentName
        )
        let initialState = Self.contentState(for: operation)
        let (stream, continuation) = AsyncStream.makeStream(of: Command.self)
        commands = continuation
        lastFlush = .now

        pumpTask = Task.detached {
            guard let activity = try? Activity<DeployActivityAttributes>.request(
                attributes: attributes,
                content: .init(state: initialState,
                               staleDate: Date().addingTimeInterval(Self.staleGrace))
            ) else { return }

            for await command in stream {
                switch command {
                case .update(let state, let staleDate):
                    await activity.update(.init(state: state, staleDate: staleDate))
                case .end(let state, let linger):
                    await activity.end(.init(state: state, staleDate: nil),
                                       dismissalPolicy: .after(.now + linger))
                    return
                case .endImmediately:
                    await activity.end(activity.content, dismissalPolicy: .immediate)
                    return
                }
            }
            // Stream finished without a terminal command (shouldn't happen) —
            // don't leave the activity stranded on the Lock Screen.
            await activity.end(activity.content, dismissalPolicy: .immediate)
        }
    }

    func update(for operation: DeploymentOperation, immediate: Bool) {
        guard commands != nil else { return }
        let state = Self.contentState(for: operation)
        if immediate || Date.now.timeIntervalSince(lastFlush) >= Self.minUpdateInterval {
            flush(state)
        } else {
            pendingState = state
            guard flushTask == nil else { return }
            let delay = Self.minUpdateInterval - Date.now.timeIntervalSince(lastFlush)
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(delay, 0.05)))
                guard !Task.isCancelled, let self, let pending = self.pendingState else { return }
                self.flush(pending)
            }
        }
    }

    func end(for operation: DeploymentOperation) {
        guard let commands else { return }
        cancelPendingFlush()
        // Let the outcome linger briefly — a touch longer on failure so it
        // can actually be read — then leave the Lock Screen.
        let linger: TimeInterval = switch operation.status {
        case .failure: 8
        default: 4
        }
        commands.yield(.end(Self.contentState(for: operation), linger: linger))
        finishPump()
    }

    /// Ends an activity without a terminal outcome (cancel / sign-out).
    func endCurrent() {
        guard let commands else { return }
        cancelPendingFlush()
        commands.yield(.endImmediately)
        finishPump()
    }

    /// Cleans up activities orphaned by an app kill mid-operation. Called once
    /// at launch — anything still alive belongs to a process that no longer
    /// exists and can never update again. Nonisolated so the non-Sendable
    /// activities never enter an actor region.
    nonisolated static func endOrphans() async {
        for orphan in Activity<DeployActivityAttributes>.activities {
            await orphan.end(orphan.content, dismissalPolicy: .immediate)
        }
    }

    private func flush(_ state: DeployActivityAttributes.ContentState) {
        cancelPendingFlush()
        lastFlush = .now
        commands?.yield(.update(state, staleDate: Date().addingTimeInterval(Self.staleGrace)))
    }

    private func cancelPendingFlush() {
        flushTask?.cancel()
        flushTask = nil
        pendingState = nil
    }

    private func finishPump() {
        commands?.finish()
        commands = nil
        pumpTask = nil
    }

    private static func contentState(for operation: DeploymentOperation) -> DeployActivityAttributes.ContentState {
        let phase: String
        let runState: DeployActivityAttributes.RunState
        switch operation.status {
        case .running:
            phase = operation.currentPhase ?? "Working"
            runState = .running
        case .success:
            phase = "Complete"
            runState = .success
        case .failure:
            phase = "Failed"
            runState = .failure
        }
        let detail = operation.lines.last.map { String($0.text.prefix(60)) }
        return .init(phase: phase,
                     progress: operation.progressFraction,
                     state: runState,
                     detail: detail)
    }
}
