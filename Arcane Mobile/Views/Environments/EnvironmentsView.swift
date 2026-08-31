import SwiftUI
import Arcane

struct EnvironmentFleetListRow: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.horizontalSizeClass) private var horizontalSizeClass
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

    private var environmentID: EnvironmentID { EnvironmentID(rawValue: environment.id) }
    private var snapshot: DashboardSnapshot? { streamState?.hasLoaded == true ? streamState?.snapshot : nil }
    private var stats: SystemStatsFrame? { series?.latest }

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactRow
            } else {
                regularRow
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 16)
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

    private var regularRow: some View {
        HStack(spacing: 12) {
            identityButton
                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)

            metric("Containers", "\(runningContainers)/\(totalContainers)")
            metric("Images", "\(imageCount)")
            metric("Updates", actionCountText(.imageUpdates))
            metric("Vulnerabilities", actionCountText(.actionableVulnerabilities))

            gauge("CPU", percent: stats?.cpuPercent, tint: .blue, systemImage: "cpu")
            gauge("Memory", percent: memoryPercent, tint: .purple, systemImage: "memorychip")
            gauge("Disk", percent: diskPercent, tint: .teal, systemImage: "internaldrive")

            actionsMenu
        }
    }

    private var compactRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                identityButton
                    .frame(maxWidth: .infinity, alignment: .leading)
                actionsMenu
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    compactMetric(
                        "Containers",
                        "\(runningContainers)/\(totalContainers)",
                        systemImage: "shippingbox"
                    )
                    compactMetric("Images", "\(imageCount)", systemImage: "photo.stack")
                }
                GridRow {
                    compactMetric(
                        "Updates",
                        actionCountText(.imageUpdates),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    compactMetric(
                        "Vulnerabilities",
                        actionCountText(.actionableVulnerabilities),
                        systemImage: "shield.lefthalf.filled"
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                gauge("CPU", percent: stats?.cpuPercent, tint: .blue, systemImage: "cpu")
                    .frame(maxWidth: .infinity)
                gauge("Memory", percent: memoryPercent, tint: .purple, systemImage: "memorychip")
                    .frame(maxWidth: .infinity)
                gauge("Disk", percent: diskPercent, tint: .teal, systemImage: "internaldrive")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var identityButton: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "server.rack")
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    Text(environment.name ?? environment.id)
                        .font(.headline)
                        .lineLimit(1)
                }
                Text(versionLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let connectionIssueLabel {
                    Text(connectionIssueLabel)
                        .font(.caption)
                        .foregroundStyle(streamState?.streamError == true ? .orange : .secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var actionsMenu: some View {
        Menu {
            if !isActive {
                Button("Use Environment", systemImage: "checkmark.circle") {
                    manager.setActiveEnvironment(id: environmentID, name: environment.name ?? environment.id)
                }
            }
            Button("View Details", systemImage: "info.circle", action: onOpen)
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
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
        }
        .accessibilityLabel("Actions for \(environment.name ?? environment.id)")
    }

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

    private func actionCountText(_ kind: ActionItemKind) -> String {
        guard let resolvedActionItems else { return "—" }
        return String(resolvedActionItems.items.first(where: { $0.kind == kind })?.count ?? 0)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(verbatim: value).font(.subheadline.monospacedDigit().weight(.semibold))
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(minWidth: 62, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
    }

    private func compactMetric(_ title: String, _ value: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(verbatim: value)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
    }

    private func gauge(_ title: String, percent: Double?, tint: Color, systemImage: String) -> some View {
        let value = min(max(percent ?? 0, 0), 100)
        let valueText = percent.map { "\(Int($0.rounded()))%" } ?? "—"
        return Gauge(value: value, in: 0...100) { Text(title) } currentValueLabel: {
            VStack(spacing: 0) {
                Image(systemName: systemImage)
                    .font(.system(size: 8, weight: .semibold))
                Text(valueText)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: value))
            }
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(tint)
        .frame(width: 44, height: 44)
        .animation(Motion.gauge, value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(percent.map { "\(Int($0.rounded())) percent" } ?? "Unavailable")
    }

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
