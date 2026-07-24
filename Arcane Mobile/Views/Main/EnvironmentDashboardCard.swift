import SwiftUI
import Arcane

struct EnvironmentDashboardCard: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let environment: Arcane.Environment
    var cachedCard: DashboardGlobalEnvironmentCard?
    /// Live per-environment state from the aggregated dashboard stream.
    var streamState: DashboardStreamStore.EnvironmentState?
    /// Authoritative Docker info loaded once by DashboardView's bounded fleet
    /// fetch and shared by cards, totals, and widgets.
    var dockerInfo: DockerInfo?
    /// Passed in by the parent instead of reading manager.activeEnvironmentID
    /// here — a body read would make every card track the manager and
    /// re-render on any manager change, not just environment switches.
    var isActive: Bool = false
    /// Live stats history owned by DashboardView's SystemStatsHistoryStore —
    /// value-passed like `streamState` so only touched cards re-evaluate, and
    /// so history is independent of card view updates.
    var series: SystemStatsHistoryStore.Series?
    var onSelect: () -> Void = {}
    var onRefresh: () async -> Void = {}

    @State private var selectionPulse = false
    @State private var showPruneSheet = false
    @State private var showUpgradeSheet = false
    @State private var isSyncing = false
    @State private var syncSuccessPulse = false
    @State private var canUpgrade = false

    var envID: EnvironmentID {
        EnvironmentID(rawValue: environment.id)
    }

    var body: some View {
        Button {
            selectionPulse.toggle()
            onSelect()
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: isActive ? "checkmark.circle.fill" : "server.rack")
                            .font(.caption.weight(.semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.primary)
                            .accessibilityHidden(true)
                        Text(environment.name ?? environment.id)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if let versionInfo = streamSnapshot?.versionInfo {
                            arcaneVersionBadge(versionInfo)
                        }
                    }
                    Text(cardStatus.text)
                        .font(.caption2)
                        .foregroundStyle(
                            cardStatus.isError
                                ? AnyShapeStyle(Color.orange)
                                : AnyShapeStyle(.secondary)
                        )
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)

                // Live metrics: sparkline chips carry both the current value
                // and a rolling minute of history (replaces the old rings —
                // they duplicated the same numbers). Fixed-height sparklines
                // (hairline placeholder until 2 samples) so data arrival never
                // changes the card frame (Liquid Glass caches the shape).
                HStack(spacing: 12) {
                    sparklineChip(
                        title: "CPU",
                        valueText: percentShort(latestStats?.cpuPercent),
                        samples: series?.cpu ?? [],
                        tint: .blue
                    )
                    sparklineChip(
                        title: "Memory",
                        valueText: percentShort(memoryPercent),
                        samples: series?.memory ?? [],
                        tint: .purple
                    )
                }
                .frame(maxWidth: .infinity)

                diskChip

                Divider()

                // Docker info includes every container; dashboard snapshots
                // intentionally omit Arcane-managed containers.
                let running = Int(dockerInfo?.containersRunning ?? 0)
                let stopped = Int(dockerInfo?.containersStopped ?? 0)
                let images = Int(dockerInfo?.images ?? 0)
                let hasAnyData = dockerInfo != nil
                HStack(spacing: 12) {
                    let miniRadius = Radius.concentric(outer: Radius.card, inset: 10)
                    DashboardMiniMetric(title: "Running", value: hasAnyData ? "\(running)" : "--", color: .green, cornerRadius: miniRadius)
                    DashboardMiniMetric(title: "Stopped", value: hasAnyData ? "\(stopped)" : "--", color: .secondary, cornerRadius: miniRadius)
                    DashboardMiniMetric(title: "Images", value: hasAnyData ? "\(images)" : "--", color: .purple, cornerRadius: miniRadius)
                }
                .frame(maxWidth: .infinity)

                // Keep this final row in the hierarchy even when empty. Live
                // stream metadata must not change card height while the user
                // is scrolling.
                actionItemsRow(streamSnapshot?.actionItems.items ?? [])
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dashboardCardBackground(cornerRadius: Radius.card)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .stroke(isActive ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 2)
            )
        }
        // Opacity-only press keeps scrolling geometry stable.
        .buttonStyle(.pressable(scales: false))
        // Round the context-menu preview to match the card; the default
        // square-cornered preview reads noticeably boxy against it.
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .contextMenu {
            if !isActive {
                Button {
                    manager.setActiveEnvironment(id: envID, name: environment.name ?? environment.id)
                } label: {
                    Label("Use Environment", systemImage: "checkmark.circle")
                }
            }
            Button {
                selectionPulse.toggle()
                onSelect()
            } label: {
                Label("View System Details", systemImage: "info.circle")
            }
            Divider()
            Button {
                Task { await runSync() }
            } label: {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(isSyncing)
            if canUpgrade {
                Button {
                    showUpgradeSheet = true
                } label: {
                    Label("Upgrade Arcane", systemImage: "arrow.up.circle")
                }
            }
            if manager.permissions.has(Permission.System.prune, in: envID) {
                Button(role: .destructive) {
                    showPruneSheet = true
                } label: {
                    Label("System Prune", systemImage: "trash")
                }
                .tint(.red)
            }
        }
        .sheet(isPresented: $showPruneSheet) {
            SystemPruneView(environmentID: envID)
        }
        .sheet(isPresented: $showUpgradeSheet) {
            NavigationStack {
                SystemUpgradeView(environmentID: envID)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showUpgradeSheet = false }
                        }
                    }
            }
        }
        .sensoryFeedback(.selection, trigger: selectionPulse)
        .sensoryFeedback(.success, trigger: syncSuccessPulse)
        .task(id: streamSnapshot?.versionInfo?.updateAvailable == true) {
            guard streamSnapshot?.versionInfo?.updateAvailable == true else {
                canUpgrade = false
                return
            }
            await checkUpgradeAvailability()
        }
    }

    /// Latest live stats frame from the shared history store.
    private var latestStats: SystemStatsFrame? { series?.latest }

    private var statsError: String? { series?.error }

    private var cardStatus: (text: String, isError: Bool) {
        if let errorBanner {
            return (errorBanner, true)
        }
        if let statsError {
            return (statsError, true)
        }
        if let version = dockerInfo?.serverVersion, !version.isEmpty {
            return ("Docker \(version)", false)
        }
        return ("Loading Docker information…", false)
    }

    /// Current value + rolling-history chip in the same raised-chip
    /// vocabulary as `DashboardMiniMetric`. Restrained — solid line + soft
    /// fill, no glow.
    private func sparklineChip(title: String, valueText: String, samples: [SparklineSample], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(valueText)
                    .font(.caption.bold())
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
                    .motionAwareAnimation(Motion.state, value: valueText)
            }
            Sparkline(samples: samples, tint: tint)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(chipBackground)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(valueText), with usage history for the last minute")
    }

    /// Disk has no meaningful minute-scale history, so it gets a capsule
    /// progress bar (the app's linear-progress vocabulary) instead.
    private var diskChip: some View {
        let percent = clampedPercent(diskPercent)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Disk")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(percentShort(diskPercent))
                    .font(.caption.bold())
                    .monospacedDigit()
                    .foregroundStyle(.teal)
                    .contentTransition(.numericText())
                    .motionAwareAnimation(Motion.state, value: percentShort(diskPercent))
            }
            ProgressView(value: percent, total: 100)
                .progressViewStyle(.linear)
                .tint(.teal)
                .scaleEffect(x: 1, y: 2, anchor: .center)
                .animation(Motion.gauge, value: percent)
            .frame(height: 8)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(chipBackground)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disk: \(percentShort(diskPercent))")
    }

    private var chipBackground: some View {
        RoundedRectangle(cornerRadius: Radius.concentric(outer: Radius.card, inset: 10), style: .continuous)
            .fill(
                Color(uiColor: .tertiarySystemGroupedBackground)
                    .shadow(.drop(color: .black.opacity(0.15), radius: 3, y: 1))
            )
    }

    /// Latest stream snapshot, gated on the one-way loaded latch so an
    /// erroring environment keeps showing its last-known counts.
    private var streamSnapshot: DashboardSnapshot? {
        guard streamState?.hasLoaded == true else { return nil }
        return streamState?.snapshot
    }

    private var errorBanner: String? {
        if streamState?.streamError == true {
            if streamState?.errorCode == .agentIncompatible {
                return "Agent version doesn't provide dashboard data; showing last known values"
            }
            return streamState?.errorMessage ?? "Live dashboard counts unavailable"
        }
        switch cachedCard?.snapshotState {
        case "ready":
            return nil
        case "error":
            return cachedCard?.snapshotError ?? "Snapshot unavailable"
        case "skipped":
            return dockerInfo == nil ? "Environment offline" : nil
        default:
            return nil
        }
    }

    // MARK: - Action items & version badge

    private func actionItemsRow(_ items: [ActionItem]) -> some View {
        let isVisible = !items.isEmpty
        let hasCritical = items.contains { $0.severity == .critical }
        let summary = items
            .prefix(2)
            .map { "\($0.count) \(Self.actionItemLabel($0.kind))" }
            .joined(separator: " · ")
        return HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(hasCritical ? .red : .orange)
                .accessibilityHidden(true)
            Text(summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .opacity(isVisible ? 1 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Needs attention: \(summary)")
        .accessibilityHidden(!isVisible)
    }

    private static func actionItemLabel(_ kind: ActionItemKind) -> String {
        switch kind {
        case .stoppedContainers: return "Stopped"
        case .imageUpdates: return "Updates"
        case .actionableVulnerabilities: return "Vulnerabilities"
        case .expiringKeys: return "Expiring Keys"
        case .unknown(let raw): return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Arcane version pill matching the web's per-environment badge: mono
    /// version text with a static amber dot when an update is available.
    /// Tappable into the upgrade sheet only when this user can upgrade.
    @ViewBuilder
    private func arcaneVersionBadge(_ info: VersionInfo) -> some View {
        let label = Self.versionBadgeText(info)
        let badge = HStack(spacing: 4) {
            Text(label)
                .font(.caption2.weight(.medium))
                .monospaced()
            if info.updateAvailable {
                Circle()
                    .fill(.orange)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(.secondary)
        .background(.secondary.opacity(0.12), in: Capsule())
        .accessibilityLabel(info.updateAvailable ? "Arcane \(label), update available" : "Arcane \(label)")

        if info.updateAvailable, canUpgrade {
            Button {
                showUpgradeSheet = true
            } label: {
                badge
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the upgrade screen")
        } else {
            badge
        }
    }

    private static func versionBadgeText(_ info: VersionInfo) -> String {
        var raw = info.displayVersion
        if raw.isEmpty { raw = info.currentTag ?? "" }
        if raw.isEmpty { raw = info.currentVersion }
        guard !raw.isEmpty else { return "unknown" }
        return raw.hasPrefix("v") ? raw : "v\(raw)"
    }

    private func percentShort(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.0f%%", min(max(v, 0), 100))
    }

    private func clampedPercent(_ v: Double?) -> Double {
        guard let v else { return 0 }
        return min(max(v, 0), 100)
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
        latestStats?.memoryTotalBytes ?? dockerInfo?.memTotal
    }

    private var diskPercent: Double? {
        guard let used = latestStats?.diskUsageBytes,
              let total = latestStats?.diskTotalBytes,
              total > 0 else { return nil }
        return (Double(used) / Double(total)) * 100.0
    }

    private func metricValue(_ value: (any BinaryInteger)?) -> String {
        guard dockerInfo != nil, let value else { return "--" }
        return "\(value)"
    }

    private func checkUpgradeAvailability() async {
        guard let client = manager.client,
              manager.currentUser?.isAdmin == true else {
            canUpgrade = false
            return
        }
        do {
            let result = try await client.system.checkUpgrade(envID: envID)
            canUpgrade = result.canUpgrade
        } catch {
            canUpgrade = false
        }
    }

    private func runSync() async {
        guard let client = manager.client else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await client.environments.sync(id: envID)
            await ResponseCache.shared.invalidateEnvironment(envID.rawValue)
            await onRefresh()
            syncSuccessPulse.toggle()
        } catch let error as ArcaneError {
            showToast(.error(arcaneMessage(error)))
        } catch {
            showToast(.error("Sync failed"))
        }
    }

    private func arcaneMessage(_ error: ArcaneError) -> String {
        switch error {
        case .rateLimited: return "Rate limited"
        case .notFound: return "Not available"
        case .unauthorized, .forbidden: return "Not authorized"
        case .server(_, let msg): return msg
        case .transport(let msg): return "Connection error: \(msg)"
        case .decoding(let msg): return "Response error: \(msg)"
        default: return "Unavailable"
        }
    }

}
