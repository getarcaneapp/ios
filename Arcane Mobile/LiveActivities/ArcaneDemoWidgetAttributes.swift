import ActivityKit
import Foundation

nonisolated
struct ArcaneDemoWidgetAttributes: ActivityAttributes, Sendable {
    nonisolated
    public struct ContentState: Codable, Hashable, Sendable {
        var startedAt: Date
        var endsAt: Date
    }
}
