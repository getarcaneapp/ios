import Arcane
import Charts
import SwiftUI

struct RefreshedDashboardIntroductionView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager

    var body: some View {
        PreviewWalkthrough(
            pages: [
                .init(
                    title: "Your hosts, live.",
                    message:
                        "A live graph follows CPU and memory on every environment, with the total across all of them up top."
                ),
                .init(
                    title: "Find what's busy.",
                    message:
                        "The busiest containers across all environments, ranked by CPU or memory. Tap one to open it."
                ),
                .init(
                    title: "Make it yours.",
                    message:
                        "Touch and hold the tiles to choose what they show. Each host lists its containers, images, volumes and disk."
                ),
            ],
            seenKey: RefreshedDashboardIntroduction.seenKey,
            footnote: "Optional preview. Turn it off anytime in More → Preview Features.",
            isEnabled: manager.refreshedDashboardPreview,
            enable: { manager.refreshedDashboardPreview = true },
            illustration: illustration
        )
    }

    @ViewBuilder
    private func illustration(_ index: Int) -> some View {
        if index == 0 {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "38.4%")
                    .font(.system(.title, design: .rounded).weight(.semibold))
                Text("3 environments · 24 cores")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            sampleChart
        } else if index == 1 {
            sampleContainer("plex", environment: "Media", color: .orange, cpu: 42.6, memory: 2_100_000_000)
            Divider()
            sampleContainer("postgres", environment: "Production", color: .blue, cpu: 18.2, memory: 1_400_000_000)
            Divider()
            sampleContainer("immich", environment: "Home", color: .teal, cpu: 9.7, memory: 3_800_000_000)
        } else {
            HStack(alignment: .top, spacing: 8) {
                DashboardStatTile(title: "Running", value: "42 / 51", icon: "cube.box.fill", tint: .orange)
                DashboardStatTile(title: "Updates", value: "3", icon: "arrow.triangle.2.circlepath", tint: .green)
                DashboardStatTile(title: "Memory", value: "61%", icon: "memorychip.fill", tint: .purple)
            }
            Divider()
            Label("Edit Tiles", systemImage: "square.grid.2x2")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.accentColor)
        }
    }

    private var sampleChart: some View {
        let lines: [(name: String, color: Color, base: Double, phase: Double)] = [
            ("Production", .blue, 28, 0),
            ("Media", .orange, 52, 1.4),
            ("Home", .teal, 14, 2.6),
        ]
        return Chart {
            ForEach(lines, id: \.name) { line in
                ForEach(0..<24, id: \.self) { step in
                    LineMark(
                        x: .value("Time", step),
                        y: .value("CPU", line.base + 9 * sin(Double(step) / 3 + line.phase)),
                        series: .value("Environment", line.name)
                    )
                    .foregroundStyle(line.color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.catmullRom)
                }
            }
        }
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 110)
    }

    private func sampleContainer(
        _ name: String, environment: String, color: Color, cpu: Double, memory: UInt64
    ) -> some View {
        HStack(spacing: 12) {
            RowIcon(systemImage: "cube.box.fill", tint: .orange, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.headline)
                HStack(spacing: 4) {
                    Image(systemName: "server.rack")
                    Text(environment)
                }
                .font(.caption)
                .foregroundStyle(color)
            }
            Spacer(minLength: 8)
            ContainerResourceMetrics(
                sample: ContainerResourceSample(cpuPercent: cpu, memoryUsageBytes: memory, memoryLimitBytes: 8_000_000_000)
            )
        }
    }
}
