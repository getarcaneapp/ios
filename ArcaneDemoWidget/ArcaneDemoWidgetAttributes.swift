import ActivityKit
import Foundation

struct ArcaneDemoWidgetAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        var startedAt: Date
        var endsAt: Date
    }
}
