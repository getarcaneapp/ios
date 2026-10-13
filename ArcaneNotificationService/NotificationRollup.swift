import Foundation

/// Dedupe and roll-up rules for push notifications, shared by the notification
/// service extension (which applies them) and the app (which tests them).
///
/// The relay groups pushes per environment and event type (`thread-id`) and
/// tags each with a content-based `dedupeKey`. When a push arrives while others
/// from the same thread are still on screen, they're replaced by one roll-up
/// that carries every item, so later roll-ups keep accumulating.
nonisolated enum NotificationRollup {
    /// One alert folded into a roll-up.
    struct Item: Codable, Hashable, Sendable {
        var label: String
        /// Alerts the server already batched ("5 image updates available") count as several.
        var count: Int
        var dedupeKey: String?
    }

    /// The fields of an alert the roll-up needs.
    struct Alert: Sendable {
        var title: String
        var body: String
        var type: String?
        var environmentName: String?
        var dedupeKey: String?
        /// Items already rolled into this alert, if it is itself a roll-up.
        var rolledUpItems: [Item]?
    }

    /// Top-level `userInfo` key holding a roll-up's items as JSON.
    static let itemsKey = "arcaneRollupItems"
    static let maxItems = 20

    // MARK: - Payload parsing

    static func alert(title: String, body: String, userInfo: [AnyHashable: Any]) -> Alert {
        let arcane = userInfo["arcane"] as? [String: Any]
        return Alert(
            title: title,
            body: body,
            type: arcane?["type"] as? String,
            environmentName: arcane?["environmentName"] as? String,
            dedupeKey: arcane?["dedupeKey"] as? String,
            rolledUpItems: decodeItems(userInfo[itemsKey])
        )
    }

    static func decodeItems(_ value: Any?) -> [Item]? {
        guard let string = value as? String, let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([Item].self, from: data)
    }

    static func encodeItems(_ items: [Item]) -> String? {
        guard let data = try? JSONEncoder().encode(items) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Rules

    /// The items an alert stands for: its stored roll-up items, or itself.
    static func items(of alert: Alert) -> [Item] {
        if let rolled = alert.rolledUpItems, !rolled.isEmpty { return rolled }
        return [
            Item(
                label: label(body: alert.body, environmentName: alert.environmentName),
                count: leadingCount(alert.title),
                dedupeKey: alert.dedupeKey
            )
        ]
    }

    /// Newest first, without repeats, capped at `maxItems`. Returns whether
    /// `incoming` repeats an alert that's already shown.
    static func merge(existing: [Item], incoming: Item) -> (items: [Item], isDuplicate: Bool) {
        let isDuplicate = existing.contains { matches($0, incoming) }
        var merged = [incoming]
        for item in existing where !merged.contains(where: { matches($0, item) }) {
            merged.append(item)
        }
        return (Array(merged.prefix(maxItems)), isDuplicate)
    }

    private static func matches(_ lhs: Item, _ rhs: Item) -> Bool {
        if let left = lhs.dedupeKey, let right = rhs.dedupeKey { return left == right }
        return lhs.label == rhs.label
    }

    /// Drops the "in <environment>" / "(<environment>)" the server appends;
    /// the roll-up shows the environment once as its subtitle.
    static func label(body: String, environmentName: String?) -> String {
        var label = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if let environmentName, !environmentName.isEmpty {
            for suffix in [" in \(environmentName)", " (\(environmentName))"] where label.hasSuffix(suffix) {
                label = String(label.dropLast(suffix.count))
            }
        }
        return label
    }

    /// "5 image updates available" counts as 5; anything else as 1.
    static func leadingCount(_ title: String) -> Int {
        let digits = title.prefix { $0.isNumber }
        guard let count = Int(digits), count > 1 else { return 1 }
        return count
    }

    static func title(type: String?, total: Int) -> String {
        switch type {
        case "image_update": "\(total) image updates available"
        case "container_update": "\(total) containers updated"
        case "vulnerability_found": "\(total) vulnerabilities found"
        case "auto_heal": "\(total) containers restarted by auto-heal"
        case "prune_report": "\(total) prunes completed"
        default: "\(total) notifications"
        }
    }

    /// Plain-language fallback when the on-device model isn't available.
    static func body(items: [Item]) -> String {
        let labels = items.map(\.label)
        let shown = labels.prefix(3)
        let remaining = labels.count - shown.count
        let list = shown.joined(separator: ", ")
        return remaining > 0 ? "\(list), and \(remaining) more" : list
    }

    /// Roll-ups of updates open the Updates tab; everything else opens the environment.
    static func route(type: String?, environmentID: String?) -> [String: String]? {
        switch type {
        case "image_update", "container_update":
            return ["kind": "tab", "tab": "updates"]
        default:
            guard let environmentID, !environmentID.isEmpty else { return nil }
            return ["kind": "environment", "environmentId": environmentID]
        }
    }
}
