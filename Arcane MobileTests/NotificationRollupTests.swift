import Foundation
import Testing

@testable import Arcane_Mobile

@Suite
struct NotificationRollupTests {
    private func userInfo(type: String, dedupeKey: String?, environmentName: String = "anran") -> [AnyHashable: Any] {
        var arcane: [String: Any] = ["type": type, "environmentName": environmentName, "environmentId": "env-1"]
        if let dedupeKey { arcane["dedupeKey"] = dedupeKey }
        return ["arcane": arcane]
    }

    @Test
    func labelDropsTheEnvironmentSuffix() {
        #expect(NotificationRollup.label(body: "nginx:latest in anran", environmentName: "anran") == "nginx:latest")
        #expect(NotificationRollup.label(body: "CVE-1 in redis (anran)", environmentName: "anran") == "CVE-1 in redis")
        #expect(NotificationRollup.label(body: "nginx:latest", environmentName: nil) == "nginx:latest")
    }

    @Test
    func batchedTitlesCountAsSeveralItems() {
        #expect(NotificationRollup.leadingCount("5 image updates available") == 5)
        #expect(NotificationRollup.leadingCount("Image update available") == 1)
    }

    @Test
    func mergeDedupesByKeyAndKeepsNewestFirst() {
        let existing = [
            NotificationRollup.Item(label: "redis", count: 1, dedupeKey: "d-b"),
            NotificationRollup.Item(label: "nginx", count: 1, dedupeKey: "d-a"),
        ]
        let repeatAlert = NotificationRollup.Item(label: "nginx", count: 1, dedupeKey: "d-a")
        let repeated = NotificationRollup.merge(existing: existing, incoming: repeatAlert)
        #expect(repeated.isDuplicate)
        #expect(repeated.items.map(\.label) == ["nginx", "redis"])

        let fresh = NotificationRollup.Item(label: "postgres", count: 1, dedupeKey: "d-c")
        let merged = NotificationRollup.merge(existing: existing, incoming: fresh)
        #expect(!merged.isDuplicate)
        #expect(merged.items.map(\.label) == ["postgres", "redis", "nginx"])
    }

    @Test
    func reorderedBatchIsADuplicateAndDoesNotAddToTheTotal() {
        let first = NotificationRollup.Item(label: "nginx:latest, redis:7, caddy:2", count: 3, dedupeKey: "d-a")
        let reordered = NotificationRollup.Item(label: "redis:7, caddy:2, nginx:latest", count: 3, dedupeKey: "d-b")
        let merged = NotificationRollup.merge(existing: [first], incoming: reordered)
        #expect(merged.isDuplicate)
        #expect(merged.items.reduce(0) { $0 + $1.count } == 3)

        let different = NotificationRollup.Item(label: "nginx:latest, redis:7", count: 2, dedupeKey: "d-c")
        #expect(!NotificationRollup.merge(existing: [first], incoming: different).isDuplicate)
    }

    @Test
    func mergeCapsTheItemList() {
        let existing = (0..<30).map { NotificationRollup.Item(label: "c\($0)", count: 1, dedupeKey: "d-\($0)") }
        let merged = NotificationRollup.merge(
            existing: existing, incoming: .init(label: "new", count: 1, dedupeKey: "d-new"))
        #expect(merged.items.count == NotificationRollup.maxItems)
        #expect(merged.items.first?.label == "new")
    }

    @Test
    func rollUpItemsRoundTripThroughUserInfo() throws {
        let items = [NotificationRollup.Item(label: "nginx", count: 2, dedupeKey: "d-a")]
        var info = userInfo(type: "image_update", dedupeKey: "d-a")
        info[NotificationRollup.itemsKey] = try #require(NotificationRollup.encodeItems(items))
        let alert = NotificationRollup.alert(title: "2 image updates available", body: "nginx", userInfo: info)
        #expect(NotificationRollup.items(of: alert) == items)
    }

    @Test
    func singleAlertBecomesOneItem() {
        let alert = NotificationRollup.alert(
            title: "Image update available", body: "nginx:latest in anran",
            userInfo: userInfo(type: "image_update", dedupeKey: "d-a"))
        #expect(
            NotificationRollup.items(of: alert) == [.init(label: "nginx:latest", count: 1, dedupeKey: "d-a")])
        #expect(alert.type == "image_update")
        #expect(alert.environmentName == "anran")
    }

    @Test
    func fallbackBodyListsThreeThenCounts() {
        let items = ["a", "b", "c", "d", "e"].map { NotificationRollup.Item(label: $0, count: 1, dedupeKey: nil) }
        #expect(NotificationRollup.body(items: items) == "a, b, c, and 2 more")
        #expect(NotificationRollup.body(items: Array(items.prefix(2))) == "a, b")
    }

    @Test
    func titlesAndRoutesFollowTheEventType() {
        #expect(NotificationRollup.title(type: "image_update", total: 3) == "3 image updates available")
        #expect(NotificationRollup.title(type: "vulnerability_found", total: 2) == "2 vulnerabilities found")
        #expect(NotificationRollup.route(type: "image_update", environmentID: "env-1")?["tab"] == "updates")
        #expect(
            NotificationRollup.route(type: "auto_heal", environmentID: "env-1")
                == ["kind": "environment", "environmentId": "env-1"])
        #expect(NotificationRollup.route(type: "auto_heal", environmentID: nil) == nil)
    }
}
