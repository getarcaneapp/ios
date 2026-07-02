import SwiftUI
import Arcane

struct EnvironmentDashboardCard: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let environment: Arcane.Environment
    var cachedCard: DashboardGlobalEnvironmentCard?
    /// Live per-environment state from the aggregated dashboard stream; takes
    /// precedence over `cachedCard` (v1) and `dockerInfo` for the counts.
    var streamState: DashboardStreamStore.EnvironmentState?
    /// Passed in by the parent instead of reading manager.activeEnvironmentID
    /// here — a body read would make every card track the manager and
    /// re-render on any manager change, not just environment switches.
    var isActive: Bool = false
    var refreshToken: Int = 0
    var onSelect: () -> Void = {}

    @State private var dockerInfo: DockerInfo?
    @State private var latestStats: SystemStatsFrame?
    @State private var dockerError: String?
    @State private var statsError: String?
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
                    if let version = dockerInfo?.serverVersion {
                        Text("Docker " + version)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)

                // Stats Rings
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    StatRing(
                        value: clampedPercent(latestStats?.cpuPercent) / 100,
                        valueText: percentShort(latestStats?.cpuPercent),
                        label: "CPU",
                        tint: .blue,
                        size: 62,
                        lineWidth: 7,
                        errorMessage: statsError
                    )
                    Spacer(minLength: 0)
                    StatRing(
                        value: clampedPercent(memoryPercent) / 100,
                        valueText: percentShort(memoryPercent),
                        label: "Memory",
                        tint: .purple,
                        size: 62,
                        lineWidth: 7,
                        errorMessage: statsError
                    )
                    Spacer(minLength: 0)
                    StatRing(
                        value: clampedPercent(diskPercent) / 100,
                        valueText: percentShort(diskPercent),
                        label: "Disk",
                        tint: .teal,
                        size: 62,
                        lineWidth: 7,
                        errorMessage: statsError
                    )
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)

                if let statsError {
                    Label(statsError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                // Mini Metrics — stream snapshot wins, then the v1 overview
                // card, then raw Docker info.
                let hasCachedCounts = cachedCard?.snapshotState == "ready"
                let running = streamSnapshot?.containers.counts.runningContainers
                    ?? cachedCard?.containers?.runningContainers
                    ?? Int(dockerInfo?.containersRunning ?? 0)
                let stopped = streamSnapshot?.containers.counts.stoppedContainers
                    ?? cachedCard?.containers?.stoppedContainers
                    ?? Int(dockerInfo?.containersStopped ?? 0)
                let images = streamSnapshot?.imageUsageCounts.totalImages
                    ?? cachedCard?.imageUsageCounts?.totalImages
                    ?? Int(dockerInfo?.images ?? 0)
                let hasAnyData = streamSnapshot != nil || hasCachedCounts || dockerInfo != nil
                HStack(spacing: 12) {
                    let miniRadius = Radius.concentric(outer: Radius.card, inset: 10)
                    DashboardMiniMetric(title: "Running", value: hasAnyData ? "\(running)" : "--", color: .green, cornerRadius: miniRadius)
                    DashboardMiniMetric(title: "Stopped", value: hasAnyData ? "\(stopped)" : "--", color: .secondary, cornerRadius: miniRadius)
                    DashboardMiniMetric(title: "Images", value: hasAnyData ? "\(images)" : "--", color: .purple, cornerRadius: miniRadius)
                }
                .frame(maxWidth: .infinity)

                if let items = streamSnapshot?.actionItems.items, !items.isEmpty {
                    actionItemsRow(items)
                }

                if let banner = errorBanner {
                    Text(banner)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dashboardCardBackground(cornerRadius: Radius.card)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .stroke(isActive ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 2)
            )
        }
        // Opacity-only press: this card is a `.matchedTransitionSource` hero-zoom
        // source, so it must not change geometry on press (a scale would disturb
        // the zoom snapshot). Feedback without breaking the push transition.
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
            Button(role: .destructive) {
                showPruneSheet = true
            } label: {
                Label("System Prune", systemImage: "trash")
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
        .task { await loadDockerInfo() }
        .task { await checkUpgradeAvailability() }
        .onChange(of: refreshToken) { _, _ in
            Task { await loadDockerInfo(refresh: true) }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let client = manager.client else { return }
            let stream = client.system.statsStream(envID: envID)
            do {
                for try await frame in stream {
                    latestStats = frame
                    statsError = nil
                }
            } catch is CancellationError {
            } catch {
                latestStats = nil
                statsError = "Live stats unavailable: \(friendlyErrorMessage(error))"
            }
        }
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
            return dockerError
        }
    }

    // MARK: - Action items & version badge

    private func actionItemsRow(_ items: [ActionItem]) -> some View {
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Needs attention: \(summary)")
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

    private func loadDockerInfo(refresh: Bool = false) async {
        guard let client = manager.client, let cached = manager.cached else { return }
        let path = client.rest.environmentPath(envID, "system/docker/info")
        let fetcher: @Sendable () async throws -> DockerInfo = {
            let rawData = try await client.transport.rawRequest(path, body: Optional<String>.none)
            return try JSONDecoder().decode(DockerInfo.self, from: rawData)
        }
        do {
            let info = try await cached.getCustom(
                path: path, as: DockerInfo.self, policy: .dockerInfo,
                envID: envID, refresh: refresh,
                onFresh: { fresh in
                    dockerInfo = fresh
                    dockerError = nil
                },
                fetcher: fetcher
            )
            await MainActor.run { 
                dockerInfo = info
                dockerError = nil 
            }
        } catch let error as ArcaneError {
            if !isCancellation(error) {
                await MainActor.run { dockerError = arcaneMessage(error) }
            }
        } catch {
            if !(error is CancellationError) {
                await MainActor.run { dockerError = "Docker info unavailable" }
            }
        }
    }

    private func isCancellation(_ error: ArcaneError) -> Bool {
        if case .transport(let msg) = error {
            return msg.lowercased().contains("cancel")
        }
        return false
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
            await loadDockerInfo()
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
