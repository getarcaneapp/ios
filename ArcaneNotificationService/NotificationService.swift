import Foundation
import UserNotifications

/// Runs for every Arcane push (the relay sets `mutable-content`) before it's
/// shown. Repeats of an alert already on screen replace it quietly, and alerts
/// that share a thread (environment + event type) are folded into one roll-up.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    /// Delivered if the system cuts the extension off mid-summary.
    private var bestAttempt: UNNotificationContent?
    private var work: Task<Void, Never>?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        lock.withLock {
            self.contentHandler = contentHandler
            bestAttempt = request.content
        }
        nonisolated(unsafe) let request = request
        work = Task { [self] in
            let content = await process(request)
            finish(with: content)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        work?.cancel()
        finish(with: nil)
    }

    private func finish(with content: UNNotificationContent?) {
        let (handler, fallback) = lock.withLock {
            let handler = contentHandler
            contentHandler = nil
            return (handler, bestAttempt)
        }
        handler?(content ?? fallback ?? UNNotificationContent())
    }

    private func setBestAttempt(_ content: UNNotificationContent) {
        lock.withLock { bestAttempt = content }
    }

    private func process(_ request: UNNotificationRequest) async -> UNNotificationContent? {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent,
            content.userInfo["arcane"] != nil
        else { return nil }

        let incoming = NotificationRollup.alert(title: content.title, body: content.body, userInfo: content.userInfo)
        let thread = content.threadIdentifier
        let center = UNUserNotificationCenter.current()
        let siblings =
            thread.isEmpty
            ? []
            : await center.deliveredNotifications().filter { $0.request.content.threadIdentifier == thread }

        let existing = siblings.flatMap { notification in
            let shown = notification.request.content
            return NotificationRollup.items(
                of: NotificationRollup.alert(title: shown.title, body: shown.body, userInfo: shown.userInfo))
        }
        guard let incomingItem = NotificationRollup.items(of: incoming).first else { return content }
        let (items, isDuplicate) = NotificationRollup.merge(existing: existing, incoming: incomingItem)

        if isDuplicate {
            // Already on screen: refresh it without another sound or banner.
            content.sound = nil
            content.interruptionLevel = .passive
        }
        guard items.count > 1 else { return content }

        let arcane = content.userInfo["arcane"] as? [String: Any]
        let total = items.reduce(0) { $0 + $1.count }
        content.title = NotificationRollup.title(type: incoming.type, total: total)
        content.subtitle = incoming.environmentName ?? ""
        content.body = NotificationRollup.body(items: items)
        var userInfo = content.userInfo
        userInfo[NotificationRollup.itemsKey] = NotificationRollup.encodeItems(items)
        if var arcane,
            let route = NotificationRollup.route(
                type: incoming.type, environmentID: arcane["environmentId"] as? String)
        {
            arcane["route"] = route
            userInfo["arcane"] = arcane
        }
        content.userInfo = userInfo

        // The roll-up replaces the siblings it absorbed. One with the same id as
        // this request is replaced by the system already.
        let absorbed = siblings.map(\.request.identifier).filter { $0 != request.identifier }
        center.removeDeliveredNotifications(withIdentifiers: absorbed)

        if let snapshot = content.copy() as? UNNotificationContent { setBestAttempt(snapshot) }
        if !Task.isCancelled,
            let summary = await NotificationSummarizer.summarize(
                title: content.title, environmentName: incoming.environmentName, items: items)
        {
            content.body = summary
        }
        return content
    }
}
