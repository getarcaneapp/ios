import Arcane
import Foundation
import Testing

@testable import Arcane_Mobile

@Suite
@MainActor
struct ContainerListSortTests {
    private typealias Key = (name: String, sample: ContainerResourceSample?)

    private func sorted(_ keys: [Key], by sort: ContainerListSort) -> [String] {
        keys.sorted { sort.areInIncreasingOrder($0, $1) }.map(\.name)
    }

    private let keys: [Key] = [
        ("web", ContainerResourceSample(cpuPercent: 5, memoryUsageBytes: 900)),
        ("db", ContainerResourceSample(cpuPercent: 40, memoryUsageBytes: 100)),
        ("idle", nil),
        ("cache", ContainerResourceSample(cpuPercent: 40, memoryUsageBytes: 500)),
    ]

    @Test
    func cpuSortPutsHeaviestFirstAndUnsampledLast() {
        #expect(sorted(keys, by: .cpuUsage) == ["cache", "db", "web", "idle"])
    }

    @Test
    func memorySortOrdersByBytes() {
        #expect(sorted(keys, by: .memoryUsage) == ["web", "cache", "db", "idle"])
    }

    @Test
    func nameSortsIgnoreSamples() {
        #expect(sorted(keys, by: .nameAscending) == ["cache", "db", "idle", "web"])
        #expect(sorted(keys, by: .nameDescending) == ["web", "idle", "db", "cache"])
    }

    @Test
    func onlyResourceSortsRequestServerSamples() {
        #expect(ContainerListSort.nameAscending.resourceSort == nil)
        #expect(ContainerListSort.nameDescending.resourceSort == nil)
        #expect(ContainerListSort.cpuUsage.resourceSort == .cpuUsage)
        #expect(ContainerListSort.memoryUsage.resourceSort == .memoryUsage)
    }

    @Test
    func metricsTextOmitsUnknownLimit() {
        let unlimited = ContainerResourceSample(cpuPercent: 12.345, memoryUsageBytes: 1_000_000)
        #expect(ContainerResourceMetrics.cpuText(unlimited) == "12.3%")
        #expect(ContainerResourceMetrics.memoryLimitText(unlimited) == nil)

        let limited = ContainerResourceSample(memoryUsageBytes: 1_000_000, memoryLimitBytes: 4_000_000)
        #expect(ContainerResourceMetrics.memoryLimitText(limited)?.hasPrefix("of ") == true)
        #expect(ContainerResourceMetrics.accessibilityDescription(limited).contains("memory"))
    }
}
