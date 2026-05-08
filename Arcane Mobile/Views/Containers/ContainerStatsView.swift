import SwiftUI
import Charts
import Arcane

struct ContainerStatsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let container: ContainerInfo
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
                    errorBanner(errorMessage)
                }

                if frames.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(isStreaming ? "Waiting for stats…" : "Connecting…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    summaryTiles
                    chartCard(title: "CPU", color: Color.accentColor, unit: "%") { frame in
                        frame.cpuPercent
                    }
                    memoryCard
                    chartCard(title: "Network I/O", colors: [.green, .orange], legend: ["RX", "TX"], unit: "B/s") { frame in
                        [frame.netRxPerSec, frame.netTxPerSec]
                    }
                    chartCard(title: "Block I/O", colors: [Color.accentColor, Color.accentColor.opacity(0.5)], legend: ["Read", "Write"], unit: "B/s") { frame in
                        [frame.blockReadPerSec, frame.blockWritePerSec]
                    }
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

    private var summaryTiles: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            tile(title: "CPU", value: percentString(latest?.cpuPercent), systemImage: "cpu", tint: Color.accentColor)
            tile(
                title: "Memory",
                value: memoryString(used: latest?.memoryUsed, limit: latest?.memoryLimit),
                subtitle: percentString(latest?.memoryPercent),
                systemImage: "memorychip",
                tint: Color.accentColor
            )
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
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
    }

    private func chartCard(title: String, color: Color, unit: String, value: @escaping (ContainerStatsFrame) -> Double) -> some View {
        chartCard(title: title, colors: [color], legend: nil, unit: unit) { frame in [value(frame)] }
    }

    private func chartCard(
        title: String,
        colors: [Color],
        legend: [String]?,
        unit: String,
        values: @escaping (ContainerStatsFrame) -> [Double]
    ) -> some View {
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
                ForEach(Array(frames.enumerated()), id: \.element.id) { idx, frame in
                    let series = values(frame)
                    ForEach(Array(series.enumerated()), id: \.offset) { sIdx, v in
                        LineMark(
                            x: .value("t", idx),
                            y: .value(unit, v)
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
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
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
            Chart {
                ForEach(Array(frames.enumerated()), id: \.element.id) { idx, frame in
                    AreaMark(
                        x: .value("t", idx),
                        y: .value("MB", Double(frame.memoryUsed) / 1_048_576)
                    )
                    .foregroundStyle(.indigo.opacity(0.25))
                    .interpolationMethod(.monotone)
                    LineMark(
                        x: .value("t", idx),
                        y: .value("MB", Double(frame.memoryUsed) / 1_048_576)
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
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
            Spacer()
            Button("Retry") {
                Task { await startStreaming() }
            }
            .font(.caption)
        }
        .padding(10)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
    }

    private func startStreaming() async {
        guard let client = manager.client else { return }
        streamTask?.cancel()
        errorMessage = nil
        let envID = environmentID
        let id = container.id
        let stream = client.containers.stats(envID: envID, id: id)
        isStreaming = true
        streamTask = Task { @MainActor in
            do {
                for try await frame in stream {
                    if Task.isCancelled { break }
                    if let parsed = ContainerStatsFrame.from(json: frame, previous: frames.last) {
                        frames.append(parsed)
                        if frames.count > windowSize {
                            frames.removeFirst(frames.count - windowSize)
                        }
                        latest = parsed
                    }
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
}
