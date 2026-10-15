import Testing

@testable import Arcane_Mobile

@Suite
struct DashboardTotalsTileTests {
    @Test
    func decodeDropsUnknownAndRepeatedTiles() {
        #expect(DashboardTotalsTile.decode("images,bogus,images,volumes") == [.images, .volumes])
    }

    @Test
    func decodeCapsAtMaximumAndFallsBackWhenEmpty() {
        let all = DashboardTotalsTile.encode(DashboardTotalsTile.allCases)
        #expect(DashboardTotalsTile.decode(all).count == DashboardTotalsTile.maximum)
        #expect(DashboardTotalsTile.decode("") == DashboardTotalsTile.defaults)
        #expect(DashboardTotalsTile.decode("bogus") == DashboardTotalsTile.defaults)
    }

    @Test
    func encodeRoundTrips() {
        let tiles: [DashboardTotalsTile] = [.memory, .running, .updates]
        #expect(DashboardTotalsTile.decode(DashboardTotalsTile.encode(tiles)) == tiles)
    }
}
