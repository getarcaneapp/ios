import SwiftUI
import Charts
import Arcane

struct ContainerStatsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let container: ContainerSummary
    let environmentID: EnvironmentID

    @State private var frames: [ContainerStatsFrame] = []
    @State private var latest: ContainerStatsFrame?
    @State private var streamTask: Task<Void, Never>?
    @State private var isStreaming = false
    @State private var errorMessage: String?

    private let windowSize = 60

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let errorMessage {
                    ErrorBanner(message: errorMessage, severity: .warning) {
                        Task { await startStreaming() }
                    }
                }

                LoadingCrossfade(showSkeleton: frames.isEmpty && errorMessage == nil) {
                    skeletonStats
                } content: {
                    loadedStats
                }
            }
            .padding()
        }
        .navigationTitle("Stats")
        .task { await startStreaming() }
        .onDisappear {
            streamTask?.cancel()
            streamTask = nil
            isStreaming = false
        }
    }

    /// Skeleton mirroring the loaded layout (tile grid + chart cards) so the
    /// first frame's arrival doesn't reflow the page.
    private var skeletonStats: some View {
        VStack(spacing: 16) {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    skeletonTile
                    skeletonTile
                }
                GridRow {
                    skeletonTile
                    skeletonTile
                }
            }
            ForEach(0..<4, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonRect(width: 90, height: 16)
                    SkeletonRect(height: 140, cornerRadius: Radius.nested)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dashboardCardBackground(cornerRadius: Radius.standard)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .skeletonShimmer()
    }

    private var skeletonTile: some View {
        VStack(alignment: .leading, spacing: 6) {
            SkeletonRect(width: 70, height: 12)
            SkeletonRect(width: 90, height: 18)
            SkeletonRect(width: 60, height: 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .dashboardCardBackground(cornerRadius: Radius.standard)
    }

    @ViewBuilder
    private var loadedStats: some View {
        if frames.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 16) {
                    summaryTiles
                    StatsChartCard(
                        title: "CPU",
                        colors: [Color.accentColor],
                        legend: nil,
                        unit: "%",
                        series: [frames.map(\.cpuPercent)]
                    )
                    .equatable()
                    memoryCard
                    StatsChartCard(
                        title: "Network I/O",
                        colors: [.green, .orange],
                        legend: ["RX", "TX"],
                        unit: "B/s",
                        series: [frames.map(\.netRxPerSec), frames.map(\.netTxPerSec)]
                    )
                    .equatable()
                    StatsChartCard(
                        title: "Block I/O",
                        colors: [Color.accentColor, Color.accentColor.opacity(0.5)],
                        legend: ["Read", "Write"],
                        unit: "B/s",
                        series: [frames.map(\.blockReadPerSec), frames.map(\.blockWritePerSec)]
                    )
                    .equatable()
            }
        }
    }

    private var summaryTiles: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                tile(title: "CPU", value: percentString(latest?.cpuPercent), systemImage: "cpu", tint: Color.accentColor)
                tile(
                    title: "Memory",
                    value: memoryString(used: latest?.memoryUsed, limit: latest?.memoryLimit),
                    subtitle: percentString(latest?.memoryPercent),
                    systemImage: "memorychip",
                    tint: Color.accentColor
                )
            }
            GridRow {
                tile(
                    title: "Network",
                    value: "↓ \(rateString(latest?.netRxPerSec))",
                    subtitle: "↑ \(rateString(latest?.netTxPerSec))",
                    systemImage: "network",
                    tint: .green
                )
                tile(
                    title: "Block I/O",
                    value: "R \(rateString(latest?.blockReadPerSec))",
                    subtitle: "W \(rateString(latest?.blockWritePerSec))",
                    systemImage: "internaldrive",
                    tint: Color.accentColor
                )
            }
        }
    }

    private func tile(title: String, value: String, subtitle: String? = nil, systemImage: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.title3, design: .rounded).bold())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .dashboardCardBackground(cornerRadius: Radius.standard)
    }

    private var memoryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Memory").font(.headline)
                Spacer()
                if let frame = latest, frame.memoryLimit > 0 {
                    Text("\(frame.memoryUsed.byteString) / \(frame.memoryLimit.byteString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            MemoryChart(points: frames.map { Double($0.memoryUsed) / 1_048_576 })
                .equatable()
        }
        .padding(12)
        .dashboardCardBackground(cornerRadius: Radius.standard)
    }

    private func startStreaming() async {
        guard let client = manager.client else { return }
        streamTask?.cancel()
        errorMessage = nil
        let envID = environmentID
        let id = container.id
        let stream = client.containers.stats(envID: envID, id: id)
        let existingFrames = frames
        let existingLatest = latest ?? existingFrames.last
        let windowSize = windowSize
        isStreaming = true
        streamTask = Task {
            var bufferedFrames = existingFrames
            var previousFrame = existingLatest
            do {
                for try await frame in stream {
                    if Task.isCancelled { break }

                    let raw = frame.raw
                    let previousSnapshot = previousFrame
                    // Offload heavy JSON framing calculations without sending the
                    // SDK payload itself across isolation boundaries.
                    let parseTask = Task.detached(priority: .userInitiated) {
                        Self.parseFrame(raw: raw, previous: previousSnapshot)
                    }
                    guard let parsed = await parseTask.value else { continue }
                    
                    previousFrame = parsed
                    bufferedFrames.append(parsed)
                    if bufferedFrames.count > windowSize {
                        bufferedFrames.removeFirst(bufferedFrames.count - windowSize)
                    }
                    frames = bufferedFrames
                    latest = parsed
                }
            } catch is CancellationError {
                // expected on view dismissal
            } catch {
                errorMessage = "Stats stream ended: \(friendlyErrorMessage(error))"
            }
            isStreaming = false
        }
    }

    private func percentString(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f%%", value)
    }

    private func memoryString(used: Int64?, limit: Int64?) -> String {
        guard let used else { return "—" }
        if let limit, limit > 0 {
            return "\(used.byteString)"
        }
        return used.byteString
    }

    private func rateString(_ bytesPerSec: Double?) -> String {
        guard let bps = bytesPerSec, bps.isFinite else { return "—" }
        let value = Int64(max(0, bps))
        return "\(value.byteString)/s"
    }

    private nonisolated static func parseFrame(
        raw: [String: JSONValue],
        previous: ContainerStatsFrame?
    ) -> ContainerStatsFrame? {
        ContainerStatsFrame.from(json: .object(raw), previous: previous)
    }
}

/// One chart card, isolated from the parent view and fed flat, precomputed
/// value arrays. `Equatable` + `.equatable()` lets SwiftUI skip re-rendering a
/// chart whose series didn't change (e.g. an idle Block I/O chart), and the
/// parent's body no longer walks `frames` with per-mark closures on every
/// streamed frame.
private struct StatsChartCard: View, Equatable {
    let title: String
    let colors: [Color]
    let legend: [String]?
    let unit: String
    /// One inner array per series, each `frames.count` long.
    let series: [[Double]]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.series == rhs.series
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let legend {
                    HStack(spacing: 10) {
                        ForEach(Array(legend.enumerated()), id: \.offset) { idx, name in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(colors[idx % colors.count])
                                    .frame(width: 8, height: 8)
                                Text(name).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Chart {
                ForEach(Array(series.enumerated()), id: \.offset) { sIdx, values in
                    ForEach(Array(values.enumerated()), id: \.offset) { idx, v in
                        LineMark(
                            x: .value("t", idx),
                            y: .value(unit, v),
                            series: .value("series", sIdx)
                        )
                        .foregroundStyle(colors[sIdx % colors.count])
                        .interpolationMethod(.monotone)
                    }
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .frame(height: 140)
        }
        .padding(12)
        .dashboardCardBackground(cornerRadius: Radius.standard)
    }
}

private struct MemoryChart: View, Equatable {
    /// Memory used per frame, in MB.
    let points: [Double]

    var body: some View {
        Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { idx, v in
                AreaMark(
                    x: .value("t", idx),
                    y: .value("MB", v)
                )
                .foregroundStyle(.indigo.opacity(0.25))
                .interpolationMethod(.monotone)
                LineMark(
                    x: .value("t", idx),
                    y: .value("MB", v)
                )
                .foregroundStyle(.indigo)
                .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .frame(height: 140)
    }
}
