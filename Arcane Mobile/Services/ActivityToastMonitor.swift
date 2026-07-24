import SwiftUI
import Observation
import Arcane

@MainActor
@Observable
final class ActivityToastMonitor {
    private static let maxRememberedActivities = 500
    private static let maxReconnectDelaySeconds: Double = 30

    private var transportIdentity: ObjectIdentifier?
    private var rememberedActivityKeys: Set<String> = []
    private var rememberedActivityOrder: [String] = []
    private var notifiedActivityKeys: Set<String> = []

    func reset() {
        transportIdentity = nil
        rememberedActivityKeys.removeAll()
        rememberedActivityOrder.removeAll()
        notifiedActivityKeys.removeAll()
    }

    func consume(client: ArcaneClient, scope: ActivityToastScope) async {
        let identity = ObjectIdentifier(client.transport)
        if transportIdentity != identity {
            transportIdentity = identity
            rememberedActivityKeys.removeAll()
            rememberedActivityOrder.removeAll()
            notifiedActivityKeys.removeAll()
        }

        var reconnectAttempt = 0
        while !Task.isCancelled {
            var receivedEvent = false
            do {
                for try await event in client.activities.stream(limit: 1) {
                    guard !Task.isCancelled else { return }
                    receivedEvent = true
                    handle(event, scope: scope)
                }
            } catch is CancellationError {
                return
            } catch {
                // The app-wide monitor is intentionally silent when a server
                // restarts or a connection drops. It reconnects below while the
                // Activity Center continues to own visible stream diagnostics.
            }

            guard !Task.isCancelled else { return }
            if receivedEvent {
                reconnectAttempt = 0
            }
            let delay = min(pow(2, Double(reconnectAttempt)), Self.maxReconnectDelaySeconds)
            reconnectAttempt += 1
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func handle(_ event: ActivityStreamEvent, scope: ActivityToastScope) {
        guard event.type == .activity, let activity = event.activity else { return }

        let environmentID = event.environmentID ?? activity.sourceEnvironmentKey
        let key = "\(environmentID)#\(activity.id)"
        let progress = activity.progress.map { Double($0) / 100 }

        switch activity.status {
        case .queued, .running:
            let firstUpdate = remember(key)
            if firstUpdate {
                guard scope.includes(activity) else { return }
                notifiedActivityKeys.insert(key)
            } else {
                guard notifiedActivityKeys.contains(key) else { return }
            }
            showActivityToast(id: key, title: toastTitle(for: activity), progress: progress)
        case .success:
            finish(key: key, activity: activity, state: .success, progress: progress)
        case .failed:
            finish(key: key, activity: activity, state: .failure, progress: progress)
        case .cancelled:
            finish(key: key, activity: activity, state: .cancelled, progress: progress)
        case .unknown:
            break
        }
    }

    private func remember(_ key: String) -> Bool {
        let insertion = rememberedActivityKeys.insert(key)
        guard insertion.inserted else { return false }

        rememberedActivityOrder.append(key)
        if rememberedActivityOrder.count > Self.maxRememberedActivities {
            let overflow = rememberedActivityOrder.count - Self.maxRememberedActivities
            let expired = rememberedActivityOrder.prefix(overflow)
            rememberedActivityKeys.subtract(expired)
            rememberedActivityOrder.removeFirst(overflow)
        }
        return true
    }

    private func toastTitle(for activity: Activity) -> String {
        activity.type.displayName
    }

    private func finish(
        key: String,
        activity: Activity,
        state: ToastActivityState,
        progress: Double?
    ) {
        guard notifiedActivityKeys.remove(key) != nil else { return }
        finishActivityToast(
            id: key,
            title: toastTitle(for: activity),
            state: state,
            progress: progress
        )
    }
}

extension View {
    func activityToastMonitor() -> some View {
        overlay { ActivityToastMonitorHost() }
    }
}

private struct ActivityToastMonitorHost: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @AppStorage("arcane.activityToastScope")
    private var scopeRawValue = ActivityToastScope.userInitiated.rawValue
    @State private var monitor = ActivityToastMonitor()

    private var canMonitor: Bool {
        guard case .authenticated = manager.authState else { return false }
        return manager.supportsActivities && manager.client != nil
    }

    private var taskID: String {
        "\(canMonitor)#\(manager.clientGeneration)#\(scopeRawValue)"
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: taskID) {
                guard canMonitor, let client = manager.client else {
                    monitor.reset()
                    return
                }
                let scope = ActivityToastScope(rawValue: scopeRawValue) ?? .userInitiated
                await monitor.consume(client: client, scope: scope)
            }
    }
}
