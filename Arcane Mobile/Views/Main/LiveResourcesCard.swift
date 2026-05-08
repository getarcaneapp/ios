import SwiftUI
import Arcane

struct LiveResourcesCard: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let environmentID: EnvironmentID
    let memoryTotalFallbackBytes: Int64?

    @State private var latestStats: SystemStatsFrame?
    @State private var streamTask: Task<Void, Never>?
    @State private var isStreaming = false
    @State private var streamError: String?

    init(environmentID: EnvironmentID, memoryTotalFallbackBytes: Int64? = nil) {
        self.environmentID = environmentID
        self.memoryTotalFallbackBytes = memoryTotalFallbackBytes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
                Text("Live Resources")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if isStreaming {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text("LIVE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.green)
                } else if streamError != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            metricRow(
                label: "CPU",
                icon: "cpu",
                color: Color.accentColor,
                percent: latestStats?.cpuPercent,
                detail: latestStats?.cpuCount.map { "\($0) core\($0 == 1 ? "" : "s")" }
            )
            metricRow(
                label: "Memory",
                icon: "memorychip",
                color: Color.accentColor,
                percent: memoryPercent,
                detail: memoryDetail
            )
            metricRow(
                label: "Disk",
                icon: "externaldrive",
                color: Color.accentColor,
                percent: diskPercent,
                detail: diskDetail
            )
        }
        .padding(16)
        .dashboardCardBackground(cornerRadius: 18)
        .onChange(of: environmentID) { _, _ in
            restartStream()
        }
        .task { startStream() }
        .onDisappear {
            streamTask?.cancel()
            streamTask = nil
            isStreaming = false
        }
    }

    @ViewBuilder
    private func metricRow(label: String, icon: String, color: Color, percent: Double?, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                    .frame(width: 18)
                Text(label)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(percentString(percent))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
            }
            ProgressView(value: clampedPercent(percent), total: 100)
                .tint(barTint(percent))
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var memoryPercent: Double? {
        if let p = latestStats?.memoryPercent { return p }
        if let used = latestStats?.memoryUsageBytes,
           let total = memoryTotalBytes, total > 0 {
            return (Double(used) / Double(total)) * 100.0
        }
        return nil
    }

    private var memoryTotalBytes: Int64? {
        latestStats?.memoryTotalBytes ?? memoryTotalFallbackBytes
    }

    private var memoryDetail: String? {
        if let used = latestStats?.memoryUsageBytes, let total = memoryTotalBytes {
            return "\(used.byteString) / \(total.byteString)"
        }
        if let total = memoryTotalBytes {
            return "Total \(total.byteString)"
        }
        return nil
    }

    private var diskPercent: Double? {
        guard let used = latestStats?.diskUsageBytes,
              let total = latestStats?.diskTotalBytes,
              total > 0 else { return nil }
        return (Double(used) / Double(total)) * 100.0
    }

    private var diskDetail: String? {
        guard let used = latestStats?.diskUsageBytes,
              let total = latestStats?.diskTotalBytes else { return nil }
        return "\(used.byteString) / \(total.byteString)"
    }

    private func startStream() {
        guard streamTask == nil, let client = manager.client else { return }
        streamError = nil
        let stream = client.system.stats(envID: environmentID, interval: 2)
        isStreaming = true
        streamTask = Task { @MainActor in
            do {
                for try await frame in stream {
                    if Task.isCancelled { break }
                    latestStats = frame
                }
            } catch is CancellationError {
                // expected
            } catch {
                streamError = "Live metrics paused"
            }
            isStreaming = false
        }
    }

    private func restartStream() {
        streamTask?.cancel()
        streamTask = nil
        latestStats = nil
        startStream()
    }

    private func percentString(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.1f%%", v)
    }

    private func clampedPercent(_ v: Double?) -> Double {
        guard let v else { return 0 }
        return min(max(v, 0), 100)
    }

    private func barTint(_ v: Double?) -> Color {
        guard let v else { return .secondary }
        if v >= 90 { return .red }
        if v >= 75 { return .orange }
        return Color.accentColor
    }
}
