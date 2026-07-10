import Arcane
import Foundation

nonisolated enum EventHistory {
    static func merged(current: [Event], incoming: [Event], limit: Int) -> [Event] {
        guard limit > 0 else { return [] }
        var byID: [String: Event] = [:]
        for event in current {
            byID[event.id] = event
        }
        for event in incoming {
            byID[event.id] = event
        }
        return byID.values
            .sorted {
                if $0.timestamp == $1.timestamp { return $0.id < $1.id }
                return $0.timestamp > $1.timestamp
            }
            .prefix(limit)
            .map { $0 }
    }
}
