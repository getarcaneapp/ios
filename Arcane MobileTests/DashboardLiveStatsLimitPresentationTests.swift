import Testing

@testable import Arcane_Mobile

@Suite
struct DashboardLiveStatsLimitPresentationTests {
    @Test
    func noticeAppearsOnlyAfterTheStreamLimit() {
        #expect(DashboardLiveStatsLimitPresentation(
            enabledEnvironmentCount: 4,
            maximumStreams: 4
        ) == nil)
        #expect(DashboardLiveStatsLimitPresentation(
            enabledEnvironmentCount: 5,
            maximumStreams: 4
        ) != nil)
    }

    @Test
    func noticeExplainsWhichMetricsAreLimitedAndWhy() throws {
        let presentation = try #require(DashboardLiveStatsLimitPresentation(
            enabledEnvironmentCount: 5,
            maximumStreams: 4
        ))

        #expect(presentation.message == "Live CPU, memory, and disk metrics are streamed for the first 4 enabled environments to stay within the server connection limit. Container and image counts still load for every environment.")
    }
}
