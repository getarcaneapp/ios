import SwiftUI
import Arcane

/// One environment card on the dashboard: identity header, a four-up metric
/// strip, and compact CPU / memory / disk rings. Data is value-passed so only
/// touched cards re-evaluate.
struct EnvironmentFleetListRow: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let environment: Arcane.Environment
    let dockerInfo: DockerInfo?
    let actionItems: ActionItems?
    let streamState: DashboardStreamStore.EnvironmentState?
    let series: SystemStatsHistoryStore.Series?
    let isActive: Bool
    let onOpen: () -> Void
    let onRefresh: () async -> Void

    @State private var showUpgrade = false
    @State private var showPrune = false
    @State private var isSyncing = false
    @State private var canUpgrade = false
    /// Rings sweep in from empty on first appear.
    @State private var gaugesRevealed = false

    private var environmentID: EnvironmentID { EnvironmentID(rawValue: environment.id) }
    private var snapshot: DashboardSnapshot? { streamState?.hasLoaded == true ? streamState?.snapshot : nil }
    private var stats: SystemStatsFrame? { series?.latest }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 16) {
                header
                ringRow
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .cardRowLinkStyle()
        .glassCardBackground(isHighlighted: isActive)
        // Round the context-menu preview to match the card; the default
        // square-cornered preview reads noticeably boxy against it.
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .contextMenu { actions }
        .accessibilityHint("Opens system details. Hold for actions.")
        .sheet(isPresented: $showPrune) { SystemPruneView(environmentID: environmentID) }
        .sheet(isPresented: $showUpgrade) {
            NavigationStack { SystemUpgradeView(environmentID: environmentID) }
        }
        .task(id: snapshot?.versionInfo?.updateAvailable == true) {
            guard snapshot?.versionInfo?.updateAvailable == true,
                  manager.permissions.has(Permission.System.upgrade, in: environmentID),
                  let client = manager.client else {
                canUpgrade = false
                return
            }
            if let result = try? await client.system.checkUpgrade(envID: environmentID) {
                canUpgrade = result.canUpgrade
            } else {
                canUpgrade = false
            }
        }
    }

    // MARK: - Header

    /// Line one: status dot, name, then icon + count pairs. Line two: version.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(statusTint)
                    .symbolEffect(.pulse, options: .repeating, isActive: streamState?.streamError == true)
                    .motionAwareAnimation(Motion.state, value: statusTint)
                    .accessibilityHidden(true)
                Text(environment.name ?? environment.id)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 10)
                countsStrip
                    .fixedSize()
            }

            HStack(spacing: 8) {
                Text(subtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(streamState?.streamError == true ? .orange : .secondary)
                    .lineLimit(1)
                if isSyncing {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .symbolEffect(.rotate, options: .repeating, isActive: true)
                        .transition(.opacity)
                        .accessibilityLabel("Syncing")
                }
            }
            .padding(.leading, 18)
        }
        .motionAwareAnimation(Motion.state, value: isSyncing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(environment.name ?? environment.id), \(subtitle)")
    }

    /// Icon + count pairs, no labels. Same glyphs, tints, and order as the
    /// overview panel, which doubles as the legend.
    private var countsStrip: some View {
        let vulnerabilities = actionCount(.actionableVulnerabilities)
        return HStack(spacing: 10) {
            count(actionCountText(.imageUpdates), systemImage: "arrow.triangle.2.circlepath", tint: .green, label: "Updates")
            count("\(runningContainers)/\(totalContainers)", systemImage: "cube.box.fill", tint: .orange, label: "Containers")
            count("\(imageCount)", systemImage: "photo.stack.fill", tint: .purple, label: "Images")
            count(
                actionCountText(.actionableVulnerabilities),
                systemImage: "exclamationmark.shield.fill",
                tint: vulnerabilities > 0 ? .red : .secondary,
                label: "Vulnerabilities",
                highlight: vulnerabilities > 0 ? .red : nil
            )
        }
    }

    private func count(
        _ value: String,
        systemImage: String,
        tint: Color,
        label: String,
        highlight: Color? = nil
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.bounce, value: value)
            Text(verbatim: value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(highlight ?? Color.primary)
                .contentTransition(.numericText())
                .motionAwareAnimation(Motion.state, value: value)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }

    /// Long-press menu for the card.
    @ViewBuilder
    private var actions: some View {
        if !isActive {
            Button("Use Environment", systemImage: "checkmark.circle") {
                manager.setActiveEnvironment(id: environmentID, name: environment.name ?? environment.id)
            }
        }
        Button("View Details", systemImage: "info.circle", action: onOpen)
        Divider()
        Button("Sync", systemImage: "arrow.triangle.2.circlepath") { Task { await sync() } }
            .disabled(isSyncing)
        if canUpgrade {
            Button("Upgrade Arcane", systemImage: "arrow.up.circle") { showUpgrade = true }
        }
        if manager.permissions.has(Permission.System.prune, in: environmentID) {
            Button(role: .destructive) { showPrune = true } label: {
                DestructiveLabel(text: "System Prune")
            }
            .tint(.red)
        }
    }

    // MARK: - Rings

    /// CPU / Memory / Disk spread evenly across the card: content-sized items
    /// with equal gaps, first flush left and last flush right.
    private var ringRow: some View {
        HStack(spacing: 0) {
            gauge("CPU", percent: stats?.cpuPercent, tint: .blue)
            Spacer(minLength: 12)
            gauge("Memory", percent: memoryPercent, tint: .purple)
            Spacer(minLength: 12)
            gauge("Disk", percent: diskPercent, tint: .teal)
        }
        .onAppear {
            guard !gaugesRevealed else { return }
            withAnimation(Motion.gaugeReveal.delay(0.2)) { gaugesRevealed = true }
        }
    }

    private func gauge(_ title: String, percent: Double?, tint: Color) -> some View {
        let value = min(max(percent ?? 0, 0), 100)
        let shown = gaugesRevealed ? value : 0
        let valueText = percent.map { "\(Int($0.rounded()))%" } ?? "—"
        return HStack(spacing: 7) {
            MetricRing(progress: shown / 100, tint: tint, size: 18, lineWidth: 3)
                .animation(Motion.gauge, value: value)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(valueText)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color.primary)
                .contentTransition(.numericText())
                .motionAwareAnimation(Motion.state, value: valueText)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(percent.map { "\(Int($0.rounded())) percent" } ?? "Unavailable")
    }

    // MARK: - Derived values

    private var runningContainers: Int { snapshot?.containers.counts.runningContainers ?? Int(dockerInfo?.containersRunning ?? 0) }
    private var totalContainers: Int { snapshot?.containers.counts.totalContainers ?? Int(dockerInfo?.containers ?? 0) }
    private var imageCount: Int { snapshot?.imageUsageCounts.totalImages ?? Int(dockerInfo?.images ?? 0) }

    private var versionLabel: String {
        nonEmptyResourceValue(snapshot?.versionInfo?.displayVersion)
            ?? nonEmptyResourceValue(dockerInfo?.serverVersion)
            ?? "Version unavailable"
    }

    private var connectionIssueLabel: String? {
        if streamState?.streamError == true { return "Partial data" }
        return dockerInfo == nil ? "Unavailable" : nil
    }

    private var subtitle: String {
        [versionLabel, connectionIssueLabel].compactMap { $0 }.joined(separator: " · ")
    }

    private var statusTint: Color {
        if streamState?.streamError == true { return .orange }
        if dockerInfo == nil, snapshot == nil { return .secondary }
        return .green
    }

    private var memoryPercent: Double? {
        if let value = stats?.memoryPercent { return value }
        guard let used = stats?.memoryUsageBytes,
              let total = stats?.memoryTotalBytes ?? dockerInfo?.memTotal,
              total > 0 else { return nil }
        return Double(used) / Double(total) * 100
    }

    private var diskPercent: Double? {
        guard let used = stats?.diskUsageBytes, let total = stats?.diskTotalBytes, total > 0 else { return nil }
        return Double(used) / Double(total) * 100
    }

    private var resolvedActionItems: ActionItems? {
        actionItems ?? snapshot?.actionItems
    }

    private func actionCount(_ kind: ActionItemKind) -> Int {
        resolvedActionItems?.items.first(where: { $0.kind == kind })?.count ?? 0
    }

    private func actionCountText(_ kind: ActionItemKind) -> String {
        guard resolvedActionItems != nil else { return "—" }
        return String(actionCount(kind))
    }

    // MARK: - Actions

    private func sync() async {
        guard let client = manager.client else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await client.environments.sync(id: environmentID)
            await ResponseCache.shared.invalidateEnvironment(environment.id)
            await onRefresh()
            showToast(.success("Environment synced"))
        } catch {
            showToast(.error("Sync failed"))
        }
    }
}

/// Small capacity ring: hairline track plus a round-capped progress arc.
/// Sized explicitly (the system `Gauge` ignores frames), so it stays tiny.
struct MetricRing: View {
    let progress: Double
    let tint: Color
    var size: CGFloat = 18
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(progress, 0), 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}
