import Foundation
import Testing

@testable import Arcane_Mobile

@Suite
struct AllEnvironmentsDashboardTests {
    private typealias Dashboard = AllEnvironmentsDashboard<Never, Never>

    @Test
    func smoothingDampsSpikesAndKeepsTimestamps() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let raw = [10.0, 10, 90, 10].enumerated().map {
            SparklineSample(timestamp: start.addingTimeInterval(Double($0.offset) * 2), value: $0.element)
        }
        let smoothed = Dashboard.smoothed(raw)
        #expect(smoothed.map(\.timestamp) == raw.map(\.timestamp))
        #expect(smoothed[0].value == 10)
        #expect(smoothed[2].value < 90 && smoothed[2].value > 10)
        #expect(smoothed[3].value > 10)
    }

    @Test
    func windowEndSnapsToTwoSecondBeat() {
        let end = Dashboard.windowEnd(for: Date(timeIntervalSinceReferenceDate: 101.7))
        #expect(end.timeIntervalSinceReferenceDate == 100)
        #expect(Dashboard.windowEnd(for: Date(timeIntervalSinceReferenceDate: 102)).timeIntervalSinceReferenceDate == 102)
    }
}
