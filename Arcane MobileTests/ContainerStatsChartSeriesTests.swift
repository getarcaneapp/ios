import Foundation
import Testing

@testable import Arcane_Mobile

@Suite("Container stats chart series")
struct ContainerStatsChartSeriesTests {
    @Test
    func buildsEveryChartSeriesInOnePass() {
        let frames = [
            frame(cpu: 10, memory: 1_048_576, receive: 20, transmit: 30, read: 40, write: 50),
            frame(cpu: 11, memory: 2_097_152, receive: 21, transmit: 31, read: 41, write: 51),
        ]

        let series = ContainerStatsChartSeries(frames: frames)

        #expect(series.cpu == [10, 11])
        #expect(series.memoryMegabytes == [1, 2])
        #expect(series.networkReceive == [20, 21])
        #expect(series.networkTransmit == [30, 31])
        #expect(series.blockRead == [40, 41])
        #expect(series.blockWrite == [50, 51])
    }

    private func frame(
        cpu: Double,
        memory: Int64,
        receive: Double,
        transmit: Double,
        read: Double,
        write: Double
    ) -> ContainerStatsFrame {
        ContainerStatsFrame(
            timestamp: .now,
            cpuPercent: cpu,
            memoryUsed: memory,
            memoryLimit: memory * 2,
            memoryPercent: 50,
            netRxBytes: 0,
            netTxBytes: 0,
            netRxPerSec: receive,
            netTxPerSec: transmit,
            blockReadBytes: 0,
            blockWriteBytes: 0,
            blockReadPerSec: read,
            blockWritePerSec: write
        )
    }
}
