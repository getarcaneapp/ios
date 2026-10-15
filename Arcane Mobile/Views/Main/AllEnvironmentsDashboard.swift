import Arcane
import Charts
import SwiftUI

/// The Refreshed Dashboard preview's body: chosen totals, a live usage chart,
/// the busiest containers, and one inventory row per host. Each figure appears
/// once — live CPU and memory live in the chart, per-host inventory in the
/// host rows, and attention items in the toolbar summary.
struct AllEnvironmentsDashboard<TotalsFootnote: View, HostsAccessory: View>: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.scenePhase) private var scenePhase

    /// Enabled environments in dashboard order.
    let environments: [Arcane.Environment]
    let dockerInfo: [String: DockerInfo]
    let statsHistory: SystemStatsHistoryStore
    let counts: Counts
    /// Volume counts per environment ID.
    let volumeCounts: [String: Int]
    var onOpenEnvironment: (Arcane.Environment) -> Void
    var onOpenContainer: (EnvironmentItem<ContainerSummary>) -> Void
    /// Opens a tile's destination; only tiles whose `opensDestination` is set call it.
    var onOpenTile: (DashboardTotalsTile) -> Void
    @ViewBuilder var totalsFootnote: TotalsFootnote
    @ViewBuilder var hostsAccessory: HostsAccessory

    @State private var usageMetric = UsageMetric.cpu
    @State private var busiestSort = ContainerResourceSort.cpuUsage
    @State private var busiestStore = BusiestContainersStore.shared
    @State private var showsTileEditor = false
    @AppStorage(DashboardTotalsTile.preferenceKey) private var storedTiles = DashboardTotalsTile.encode(DashboardTotalsTile.defaults)

    /// All-environment totals from the dashboard's existing count sources.
    struct Counts: Equatable {
        var running: Int?
        var total: Int?
        var images: Int?
        var volumes: Int?
        var updates: Int?
        var vulnerabilities: Int?

        var stopped: Int? { running.flatMap { running in total.map { $0 - running } } }
    }

    private static var busiestLimit: Int { 5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            VStack(alignment: .leading, spacing: 10) {
                totalsCard
                totalsFootnote
            }
            .cardEntrance(id: "dashboard.all.totals", index: 0)
            usageCard
                .cardEntrance(id: "dashboard.all.usage", index: 1)
            if showsBusiest {
                busiestSection
                    .cardEntrance(id: "dashboard.all.busiest", index: 2)
            }
            hostsSection
                .cardEntrance(id: "dashboard.all.hosts", index: 3)
        }
        .task(id: SamplePollKey(environmentIDs: environments.map(\.id), isActive: scenePhase == .active)) {
            busiestStore.activate(cacheKey: "\(manager.serverURL)|\(manager.currentUser?.id ?? "")")
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                if let client = manager.client {
                    await busiestStore.refresh(client: client, environments: environmentIDs)
                }
                try? await Task.sleep(for: BusiestContainersStore.refreshInterval)
            }
        }
    }

    // MARK: - Totals

    private var totalsCard: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(DashboardTotalsTile.decode(storedTiles)) { tile in
                DashboardStatTile(
                    title: tile.title,
                    value: value(for: tile),
                    icon: tile.systemImage,
                    tint: tile.tint,
                    action: tile.opensDestination ? { onOpenTile(tile) } : nil
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .glassCardBackground()
        .contextMenu {
            Button("Edit Tiles", systemImage: "square.grid.2x2") { showsTileEditor = true }
        }
        .sheet(isPresented: $showsTileEditor) {
            NavigationStack {
                DashboardTilesEditor()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsTileEditor = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func value(for tile: DashboardTotalsTile) -> String {
        let live = environments.compactMap { statsHistory.series(for: $0.id)?.latest }
        let count: (Int?) -> String = { $0.map(String.init) ?? "—" }
        switch tile {
        case .running:
            return counts.running.flatMap { running in counts.total.map { "\(running) / \($0)" } } ?? "—"
        case .stopped: return count(counts.stopped)
        case .images: return count(counts.images)
        case .volumes: return count(counts.volumes)
        case .updates: return count(counts.updates)
        case .vulnerabilities: return count(counts.vulnerabilities)
        case .hostsOnline:
            return "\(environments.filter { $0.isOnline == true }.count) / \(environments.count)"
        case .cpuCores:
            return live.isEmpty ? "—" : String(live.reduce(0) { $0 + $1.cpuCount })
        case .memory:
            let total = live.reduce(Int64(0)) { $0 + $1.memoryTotalBytes }
            guard total > 0 else { return "—" }
            let used = live.reduce(Int64(0)) { $0 + $1.memoryUsageBytes }
            return String(format: "%.0f%%", Double(used) / Double(total) * 100)
        }
    }

    // MARK: - Live usage

    enum UsageMetric: String, CaseIterable, Identifiable {
        case cpu = "CPU"
        case memory = "Memory"
        var id: String { rawValue }
    }

    private struct UsageLine: Identifiable {
        let id: String
        let name: String
        let color: Color
        let samples: [SparklineSample]
        let current: Double?
    }

    /// The chart's visible span; matches the history store's five-minute window.
    private static var usageWindow: TimeInterval { 300 }

    /// Streamed environments only; the rest have no live series.
    private var usageLines: [UsageLine] {
        environments.enumerated().compactMap { index, environment in
            guard let series = statsHistory.series(for: environment.id), series.latest != nil else { return nil }
            let samples = usageMetric == .cpu ? series.cpu : series.memory
            return UsageLine(
                id: environment.id,
                name: environment.displayName,
                color: color(for: environment, index: index),
                samples: Self.smoothed(samples),
                current: samples.last?.value
            )
        }
    }

    /// Snaps the window's right edge to the stream's 2s cadence.
    nonisolated static func windowEnd(for newest: Date, step: TimeInterval = 2) -> Date {
        Date(timeIntervalSinceReferenceDate: (newest.timeIntervalSinceReferenceDate / step).rounded(.down) * step)
    }

    /// Exponential moving average for display: 2s host samples jitter enough
    /// that the raw line reads as noise rather than a trend.
    nonisolated static func smoothed(_ samples: [SparklineSample], weight: Double = 0.35) -> [SparklineSample] {
        var average: Double?
        return samples.map { sample in
            let next = average.map { $0 + weight * (sample.value - $0) } ?? sample.value
            average = next
            return SparklineSample(timestamp: sample.timestamp, value: next)
        }
    }

    private var usageHeadline: (value: String, detail: String)? {
        let stats = environments.compactMap { statsHistory.series(for: $0.id)?.latest }
        guard !stats.isEmpty else { return nil }
        let hosts = stats.count == 1 ? "1 environment" : "\(stats.count) environments"
        switch usageMetric {
        case .cpu:
            // Weighted by cores so a busy 2-core box doesn't read like a busy 64-core one.
            let cores = stats.reduce(0) { $0 + max($1.cpuCount, 1) }
            let weighted = stats.reduce(0.0) { $0 + $1.cpuPercent * Double(max($1.cpuCount, 1)) }
            return (String(format: "%.1f%%", weighted / Double(cores)), "\(hosts) · \(cores) cores")
        case .memory:
            let used = stats.reduce(Int64(0)) { $0 + $1.memoryUsageBytes }
            let total = stats.reduce(Int64(0)) { $0 + $1.memoryTotalBytes }
            guard total > 0 else { return nil }
            let percent = Double(used) / Double(total) * 100
            return (
                String(format: "%.0f%%", percent),
                "\(used.byteString) of \(total.byteString) · \(hosts)"
            )
        }
    }

    private var usageCard: some View {
        let lines = usageLines
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: usageHeadline?.value ?? "—")
                        .font(.system(.title, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .motionAwareAnimation(Motion.state, value: usageHeadline?.value)
                    if let detail = usageHeadline?.detail {
                        Text(verbatim: detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                Picker("Metric", selection: $usageMetric.animation(Motion.state)) {
                    ForEach(UsageMetric.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

            if lines.allSatisfy({ $0.samples.count < 2 }) {
                ArcaneLoadingView("Waiting for live stats…", style: .inline)
                    .font(.caption)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                usageChart(lines)
            }

            if !lines.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10, alignment: .leading)], spacing: 8) {
                    ForEach(lines) { line in
                        HStack(spacing: 6) {
                            Circle().fill(line.color).frame(width: 8, height: 8)
                            Text(verbatim: line.name)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(verbatim: line.current.map { String(format: "%.0f%%", $0) } ?? "—")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                                .motionAwareAnimation(Motion.state, value: line.current.map { Int($0) })
                        }
                        .font(.caption)
                    }
                }
            }

            if environments.count > SystemStatsHistoryStore.maxStreams {
                Text("Live usage covers the first \(SystemStatsHistoryStore.maxStreams) environments. Change this in App Settings.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .glassCardBackground()
        .accessibilityElement(children: .contain)
    }

    private func usageChart(_ lines: [UsageLine]) -> some View {
        // A fixed-width window on a 2s clock: every environment's newest sample
        // slides in from the right edge on the same beat, rather than each
        // stream's arrival restarting the scroll or rescaling the axis.
        let newest = lines.compactMap { $0.samples.last?.timestamp }.max() ?? Date()
        let end = Self.windowEnd(for: newest)
        let start = end.addingTimeInterval(-Self.usageWindow)
        return Chart {
            ForEach(lines) { line in
                ForEach(line.samples, id: \.timestamp) { sample in
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value(usageMetric.rawValue, sample.value),
                        series: .value("Environment", line.id)
                    )
                    .foregroundStyle(line.color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)
                }
                // A single host gets the soft fill; overlapping fills would muddy several.
                if lines.count == 1 {
                    ForEach(line.samples, id: \.timestamp) { sample in
                        AreaMark(
                            x: .value("Time", sample.timestamp),
                            y: .value(usageMetric.rawValue, sample.value)
                        )
                        .foregroundStyle(
                            .linearGradient(
                                colors: [line.color.opacity(0.25), line.color.opacity(0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)
                    }
                }
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: 0...100)
        .chartPlotStyle { $0.clipped() }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                AxisValueLabel {
                    if let percent = value.as(Int.self) { Text(verbatim: "\(percent)%") }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartLegend(.hidden)
        .frame(height: 150)
        .motionAwareAnimation(Motion.chartScroll, value: end)
        .accessibilityLabel("\(usageMetric.rawValue) usage over time for each environment")
    }

    // MARK: - Busiest containers

    private var environmentIDs: [EnvironmentID] {
        environments.map { EnvironmentID(rawValue: $0.id) }
    }

    /// Hidden once every environment turns out to predate the shared stats collector.
    private var showsBusiest: Bool {
        busiestStore.supportsAny(environmentIDs)
    }

    private var busiestSection: some View {
        let busiest = busiestStore.top(by: busiestSort, limit: Self.busiestLimit, environments: environmentIDs)
        let names = Dictionary(environments.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    DashboardSectionTitle("Busiest Containers")
                    // Saved rows show their age until the first live refresh lands.
                    if !busiestStore.isLive, let updatedAt = busiestStore.updatedAt, !busiest.isEmpty {
                        Text("Updated \(updatedAt, format: .relative(presentation: .named))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }
                Spacer()
                Picker("Sort", selection: $busiestSort.animation(Motion.reflow)) {
                    Text("CPU").tag(ContainerResourceSort.cpuUsage)
                    Text("Memory").tag(ContainerResourceSort.memoryUsage)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

            VStack(spacing: 0) {
                if busiest.isEmpty {
                    Group {
                        if busiestStore.isLive {
                            Text("No running containers.")
                                .foregroundStyle(.secondary)
                        } else {
                            ArcaneLoadingView("Sampling containers…", style: .inline)
                        }
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    ForEach(Array(busiest.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider().padding(.leading, 64) }
                        let item = EnvironmentItem(
                            entry.container,
                            in: ListEnvironment(id: entry.environmentID, name: names[entry.environmentID.rawValue])
                        )
                        Button {
                            onOpenContainer(item)
                        } label: {
                            ContainerRow(
                                container: entry.container,
                                environmentName: item.environmentName,
                                metrics: .sample(entry.sample)
                            )
                            .rowEnvironment(item)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .contentShape(.rect)
                        }
                        .cardRowLinkStyle()
                    }
                }
            }
            .padding(.vertical, 4)
            // Rows trade places smoothly as fresh samples reorder them.
            .motionAwareAnimation(Motion.reflow, value: busiest.map(\.id))
            .motionAwareAnimation(Motion.state, value: busiestStore.isLive)
            .glassCardBackground()
        }
    }

    // MARK: - Hosts

    private var hostsSection: some View {
        let online = environments.filter { $0.isOnline == true }.count
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    DashboardSectionTitle("Hosts")
                    Text(verbatim: "\(online) of \(environments.count) online")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                hostsAccessory
            }

            VStack(spacing: 0) {
                ForEach(Array(environments.enumerated()), id: \.element.id) { index, environment in
                    if index > 0 { Divider().padding(.leading, 16) }
                    Button {
                        onOpenEnvironment(environment)
                    } label: {
                        hostRow(environment, index: index)
                    }
                    .cardRowLinkStyle()
                }
            }
            .padding(.vertical, 4)
            .glassCardBackground()
        }
    }

    private func hostRow(_ environment: Arcane.Environment, index: Int) -> some View {
        let stats = statsHistory.series(for: environment.id)?.latest
        let info = dockerInfo[environment.id]
        let isOnline = environment.isOnline == true
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color(for: environment, index: index))
                    .frame(width: 8, height: 8)
                Text(verbatim: environment.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !isOnline {
                    Text("Offline")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                DashboardRowChevron()
            }
            // Inventory and disk only: live CPU and memory are the chart's job.
            HStack(alignment: .top, spacing: 14) {
                HostStat(
                    title: "Running",
                    value: info.map { "\($0.containersRunning)/\($0.containers)" },
                    meter: .init(
                        fraction: info.flatMap {
                            $0.containers > 0 ? Double($0.containersRunning) / Double($0.containers) : nil
                        },
                        tint: .green
                    )
                )
                HostStat(title: "Images", value: info.map { String($0.images) })
                HostStat(title: "Volumes", value: volumeCounts[environment.id].map(String.init))
                HostStat(
                    title: "Disk",
                    value: diskPercent(stats).map { String(format: "%.0f%%", $0) },
                    meter: .init(fraction: diskPercent(stats).map { $0 / 100 }, tint: .teal, warnsAbove: 0.9)
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hostAccessibilityLabel(environment, stats: stats, info: info, isOnline: isOnline))
        .accessibilityAddTraits(.isButton)
    }

    private func diskPercent(_ stats: SystemStats?) -> Double? {
        guard let used = stats?.diskUsageBytes, let total = stats?.diskTotalBytes, total > 0 else { return nil }
        return Double(used) / Double(total) * 100
    }

    private func hostAccessibilityLabel(
        _ environment: Arcane.Environment, stats: SystemStats?, info: DockerInfo?, isOnline: Bool
    ) -> String {
        var parts = [environment.displayName, isOnline ? "online" : "offline"]
        if let info {
            parts.append("\(info.containersRunning) of \(info.containers) containers running")
            parts.append("\(info.images) images")
        }
        if let volumes = volumeCounts[environment.id] { parts.append("\(volumes) volumes") }
        if let disk = diskPercent(stats) { parts.append(String(format: "disk %.0f percent full", disk)) }
        return parts.joined(separator: ", ")
    }

    // MARK: - Helpers

    private static var fallbackColors: [Color] { [.blue, .orange, .pink, .teal, .indigo, .yellow, .cyan, .brown] }

    /// The environment's chosen color, else a stable palette slot.
    private func color(for environment: Arcane.Environment, index: Int) -> Color {
        EnvironmentColorStore.shared.hex(server: manager.serverURL, environmentID: environment.id)
            .flatMap(Color.init(hex:))
            ?? Self.fallbackColors[index % Self.fallbackColors.count]
    }

    private struct SamplePollKey: Equatable {
        let environmentIDs: [String]
        let isActive: Bool
    }
}

/// One host figure: label and value, with an optional thin capsule meter. A
/// meter past `warnsAbove` turns orange so a nearly full disk stands out
/// without a banner. Columns without a meter keep its space so every value in
/// a row lines up.
private struct HostStat: View {
    struct Meter {
        var fraction: Double?
        var tint: Color
        var warnsAbove: Double? = nil

        var fill: Color {
            if let warnsAbove, let fraction, fraction >= warnsAbove { return .orange }
            return tint
        }
    }

    let title: String
    let value: String?
    var meter: Meter? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(verbatim: value ?? "—")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .motionAwareAnimation(Motion.state, value: value)
            Capsule()
                .fill(Color.secondary.opacity(0.15))
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(meter?.fill ?? .clear)
                            .frame(width: proxy.size.width * min(max(meter?.fraction ?? 0, 0), 1))
                            .motionAwareAnimation(Motion.gauge, value: meter?.fraction)
                    }
                }
                .opacity(meter == nil ? 0 : 1)
                .accessibilityHidden(true)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
