import Arcane
import Foundation
import Testing

@testable import Arcane_Mobile

@Suite
struct EventHistoryTests {
    @Test
    func mergeDeduplicatesSortsAndTrimsToLoadedLimit() {
        let now = Date()
        let current = [event(id: "a", title: "old", date: now.addingTimeInterval(-10))]
        let incoming = [
            event(id: "a", title: "updated", date: now),
            event(id: "b", title: "second", date: now.addingTimeInterval(-1)),
            event(id: "c", title: "trimmed", date: now.addingTimeInterval(-2))
        ]

        let merged = EventHistory.merged(current: current, incoming: incoming, limit: 2)

        #expect(merged.map(\.id) == ["a", "b"])
        #expect(merged.first?.title == "updated")
    }

    private func event(id: String, title: String, date: Date) -> Event {
        Event(
            id: id,
            type: "test",
            severity: "info",
            title: title,
            timestamp: date,
            createdAt: date
        )
    }
}
