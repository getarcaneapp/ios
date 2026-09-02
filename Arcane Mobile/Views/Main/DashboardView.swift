import SwiftUI
import UIKit
import Arcane

nonisolated struct DashboardGlobalOverview: Decodable, Sendable {
    let summary: DashboardEnvironmentsSummary
    let environments: [DashboardGlobalEnvironmentCard]?
}

nonisolated private struct DashboardOverviewEnvelope: Decodable, Sendable {
    let success: Bool?
    let data: DashboardGlobalOverview?
}

struct DashboardGlobalEnvironmentCard: Decodable, Sendable, Identifiable {
    var id: String { environment.id }
    let environment: DashboardGlobalEnvironmentBase
    let containers: DashboardEnvironmentsSummary.DashboardContainerCounts?
    let imageUsageCounts: DashboardEnvironmentsSummary.DashboardImageCounts?
    let versionInfo: DashboardGlobalVersionInfo?
    let snapshotState: String?
    let snapshotError: String?

    struct DashboardGlobalVersionInfo: Decodable, Sendable {
        let currentVersion: String?
    }

    struct DashboardGlobalEnvironmentBase: Decodable, Sendable {
        let id: String
        let name: String?
    }
}

struct DashboardEnvironmentsSummary: Decodable, Sendable {
    let totalEnvironments: Int?
    let onlineEnvironments: Int?
    let containers: DashboardContainerCounts?
    let imageUsageCounts: DashboardImageCounts?

    struct DashboardContainerCounts: Decodable, Sendable {
        let totalContainers: Int?
        let runningContainers: Int?
        let stoppedContainers: Int?
    }
    struct DashboardImageCounts: Decodable, Sendable {
        let totalImages: Int?
    }
}

struct EnvironmentDetailRoute: Hashable {
    let id: String
    let name: String
}

/// Aggregated container/image counts derived live from per-environment
/// `system/docker/info`, used as the authoritative source for the dashboard
/// tiles because dashboard snapshots exclude Arcane-managed containers.
private struct DashboardLiveCounts: Sendable, Equatable {
    var running: Int
    var stopped: Int
    var total: Int
    var images: Int
}

private struct DashboardFleetCountResult: Sendable {
    let total: Int?
    let unavailableEnvironmentIDs: [String]
}

private struct DashboardCountIssue: Identifiable {
    let id: String
    let title: String
    let detail: String
}

private struct DashboardCountAvailability: Identifiable {
    let id = UUID()
    let issues: [DashboardCountIssue]
}

nonisolated struct DashboardLiveStatsLimitPresentation: Equatable, Sendable {
    let maximumStreams: Int

    init?(enabledEnvironmentCount: Int, maximumStreams: Int) {
        guard maximumStreams > 0, enabledEnvironmentCount > maximumStreams else { return nil }
        self.maximumStreams = maximumStreams
    }

    var message: String {
        "Live CPU, memory, and disk metrics are streamed for the first \(maximumStreams) enabled environments to stay within the server connection limit. Container and image counts still load for every environment."
    }
}

private enum DashboardEnvironmentLiveState: Sendable, Equatable {
    case online(DockerInfo)
    case offline

    var dockerInfo: DockerInfo? {
        guard case .online(let info) = self else { return nil }
        return info
    }
}

struct DashboardView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ImageUpdateCountStore.self) private var imageUpdateCountStore
    @SwiftUI.Environment(ActivityHistoryMutationStore.self) private var historyMutationStore
    @SwiftUI.Environment(PinnedItemsStore.self) private var pinnedStore
    @SwiftUI.Environment(FleetStore.self) private var fleet
    @SwiftUI.Environment(\.scenePhase) private var scenePhase
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selectedTab: String
    var showsSidebarButton = false
    var onOpenSidebar: () -> Void = {}
    var onNavigationRootChange: (Bool) -> Void = { _ in }

    @State private var allEnvironments: [Arcane.Environment] = []
    @State private var environments: [Arcane.Environment] = []
    @State private var overview: DashboardGlobalOverview?
    @State private var volumesTotal: Int?
    @State private var supplementalImageUpdatesTotal: Int?
    @State private var liveCounts: DashboardLiveCounts?
    @State private var environmentLiveStates: [String: DashboardEnvironmentLiveState] = [:]
    @State private var volumeCountUnavailableEnvironmentIDs: [String] = []
    @State private var updateCountUnavailableEnvironmentIDs: [String] = []
    @State private var hasLoadedFleetCounts = false
    @State private var countAvailabilityPresentation: DashboardCountAvailability?
    @State private var failedActivities: [Activity] = []
    @State private var rawEnvironmentCount: Int = 0
    @State private var detailRoute: EnvironmentDetailRoute?
    @State private var containerRoute: ContainerSummary?
    @State private var projectRoute: ProjectDetails?
    /// Pushes AllVulnerabilitiesView for the environment named in the route.
    @State private var vulnerabilityRoute: EnvironmentDetailRoute?
    @State private var showAPIKeys = false
    /// Compact summary popover anchored to the top-left toolbar button.
    @State private var showAttentionSummary = false
    /// Full Attention Center sheet.
    @State private var showAttentionCenter = false
    @State private var quickActionRouter = QuickActionRouter.shared
    /// Guards the scenePhase handler — hidden tab pages also receive scene
    /// phase changes and must not start their own stream.
    @State private var isDashboardVisible = false

    @State private var isLoading = false
    @State private var hasLoadedOnce = false
    /// True only after an environments fetch actually succeeded — gates the
    /// "No Environments" empty state so a cancelled/failed first load can't
    /// flash it before data arrives.
    @State private var hasLoadedEnvironments = false
    /// Bumped on pull-to-refresh so per-environment rows force-refetch their own
    /// `system/docker/info` — their `.task` does not re-run on a parent refresh.
    @State private var cardRefreshToken = 0
    @State private var showPruneSheet = false
    @State private var showVolumes = false
    @State private var showImageUpdates = false
    @State private var showUpdateAll = false
    /// First tap arms the Update All button (it expands into a confirm
    /// capsule); the second tap starts the run. Disarms itself after a moment.
    @State private var isUpdateAllArmed = false
    @State private var updateAllDisarmTask: Task<Void, Never>?
    @State private var liveCountsRefreshTask: Task<Void, Never>?
    @State private var visibleEnvironmentCount = 50

    private static let environmentBatchSize = 50
    private static let maxConcurrentPerEnvFetches = 4

    private var envID: EnvironmentID { manager.activeEnvironmentID }
    private var streamStore: DashboardStreamStore { fleet.dashboardStream }
    private var statsHistory: SystemStatsHistoryStore { fleet.statsHistory }

    private var liveStatsLimitPresentation: DashboardLiveStatsLimitPresentation? {
        DashboardLiveStatsLimitPresentation(
            enabledEnvironmentCount: allEnvironments.filter(\.enabled).count,
            maximumStreams: SystemStatsHistoryStore.maxStreams
        )
    }

    private var canPrune: Bool {
        manager.permissions.has(Permission.System.prune, in: envID)
    }

    private var imageUpdatesTotal: Int? {
        let sharedTotal = imageUpdateCountStore.total(
            client: manager.client,
            userID: manager.currentUser?.id,
            environmentIDs: allEnvironments.filter(\.enabled).map {
                EnvironmentID(rawValue: $0.id)
            }
        )
        return DashboardImageUpdateCountResolver.resolve(
            shared: sharedTotal,
            streamed: streamStore.aggregate?.imageUpdates,
            supplemental: supplementalImageUpdatesTotal
        )
    }

    private var isNavigationRoot: Bool {
        detailRoute == nil
            && containerRoute == nil
            && projectRoute == nil
            && vulnerabilityRoute == nil
            && !showAPIKeys
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 36) {
                    if showsSkeleton {
                        skeletonContent
                    } else if showsEmptyState {
                        ContentUnavailableView {
                            Label("No Environments", systemImage: "server.rack")
                        } description: {
                            Text("Connect an environment to see live container, image, and system stats here.")
                        }
                        .padding(.top, 48)
                    } else {
                        overviewSection

                        if hasPinnedDashboardResources {
                            DashboardPinnedSection(
                                refreshToken: cardRefreshToken,
                                onOpenContainer: { containerRoute = $0 },
                                onOpenProject: { projectRoute = $0 }
                            )
                            .cardEntrance(id: "dashboard.pinned", index: 4)
                            .scrollEdgeFade()
                        }

                        environmentsSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .softTopScrollEdgeEffectCompat()
            .navigationTitle("Dashboard")
            .navigationBarTitleDisplayMode(.large)
            .modifier(DashboardDateSubtitle())
            .toolbar {
                if showsSidebarButton, isNavigationRoot {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: onOpenSidebar) {
                            Image(systemName: "line.3.horizontal")
                                .appAccentToolbarSymbol()
                        }
                        .accessibilityLabel("Open navigation")
                    }
                }

                // Needs Attention lives in the toolbar: the button expands into
                // a compact summary popover, which opens the full Attention
                // Center sheet.
                if isNavigationRoot {
                    ToolbarItem(placement: .topBarLeading) {
                        AttentionToolbarButton(
                            items: needsAttentionItems,
                            isPresented: $showAttentionSummary,
                            onSelect: { item in performAttentionAction(item.action) },
                            onOpenCenter: { performAttentionAction { showAttentionCenter = true } }
                        )
                    }
                }


                // Tab-bar mode has no sidebar hosting the Activity Center, so
                // the dashboard toolbar is its standing entry point. Sidebar
                // mode already exposes it next to the sidebar wordmark.
                if !showsSidebarButton, isNavigationRoot, manager.supportsActivities {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        DashboardActivityToolbarButton {
                            quickActionRouter.openActivityCenter()
                        }
                    }
                }

                // Keep Activity Center and Prune as two separate glass
                // buttons instead of one shared pill.
                if #available(iOS 26, *), !showsSidebarButton, isNavigationRoot, manager.supportsActivities, canPrune {
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }

                if canPrune {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showPruneSheet = true } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .accessibilityLabel("System Prune")
                    }
                }
            }
            .sheet(isPresented: $showAttentionCenter) {
                AttentionCenterView(items: needsAttentionItems) { item in
                    performAttentionAction(item.action)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showUpdateAll) {
                NavigationStack {
                    UpdateAllEnvironmentsView(environmentCount: rawEnvironmentCount, startsImmediately: true)
                }
                .presentationDetents([.medium, .large])
                .presentationContentInteraction(.resizes)
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showPruneSheet) {
                SystemPruneView(environmentID: envID)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showVolumes) {
                NavigationStack {
                    VolumesView(
                        environmentID: envID,
                        environmentName: manager.activeEnvironmentName
                    )
                }
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showImageUpdates) {
                NavigationStack {
                    // Starting an update dismisses this sheet so the root
                    // pill (above the tab bar) becomes the progress surface.
                    AllEnvironmentsImageUpdatesView(dismissOnOperationStart: true)
                }
                // Pre-flight error toasts must be visible while the sheet is
                // up — the root toast host is covered by it.
                .toastHost(reservesTabBarSpace: false)
                .presentationDragIndicator(.visible)
            }
            .navigationDestination(item: $detailRoute) { route in
                SystemInfoDetailView(
                    environmentID: EnvironmentID(rawValue: route.id),
                    environmentName: route.name
                )
            }
            .navigationDestination(item: $containerRoute) { container in
                ContainerDetailView(container: container, environmentID: manager.activeEnvironmentID)
            }
            .navigationDestination(item: $projectRoute) { project in
                ProjectDetailView(project: project, environmentID: manager.activeEnvironmentID)
            }
            .navigationDestination(item: $vulnerabilityRoute) { route in
                AllVulnerabilitiesView(environmentID: EnvironmentID(rawValue: route.id))
            }
            .navigationDestination(isPresented: $showAPIKeys) {
                APIKeysView()
            }
            .task { await loadData() }
            .refreshable { await refreshDashboard() }
            .onChange(of: manager.activeEnvironmentID.rawValue) {
                environments = dashboardEnvironments(from: allEnvironments.isEmpty ? environments : allEnvironments)
                // The active environment moved to the front, which can change
                // which environments fall inside the history-stream cap.
                fleet.prioritizeStats(activeEnvironmentID: manager.activeEnvironmentID.rawValue)
            }
            .onChange(of: fleet.environmentCatalogRevision, initial: true) {
                updateEnvironmentCatalogFromStore()
            }
            .onChange(of: fleet.dockerInformationRevision, initial: true) {
                updateFleetLiveStateFromStore()
            }
            // The aggregated dashboard stream covers all environments over one
            // connection. v1 servers never get the endpoint, so don't attempt
            // it there; v2 servers that predate it 404 once and the store
            // latches into silent legacy mode.
            .task(id: manager.client.map { ObjectIdentifier($0.transport) }) {
                fleet.configure(client: manager.client)
                fleet.setVisible(true, consumer: "dashboard", supportsDashboardStream: manager.supportsActivities)
            }
            .onAppear {
                isDashboardVisible = true
            }
            .onDisappear {
                isDashboardVisible = false
                liveCountsRefreshTask?.cancel()
                liveCountsRefreshTask = nil
                fleet.setVisible(false, consumer: "dashboard", supportsDashboardStream: manager.supportsActivities)
            }
            .onChange(of: streamStore.aggregate) { previous, current in
                publishWidgetSnapshot()
                guard current != nil, current != previous else { return }
                liveCountsRefreshTask?.cancel()
                liveCountsRefreshTask = Task { await refreshLiveCounts() }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    liveCountsRefreshTask?.cancel()
                    liveCountsRefreshTask = nil
                    fleet.setVisible(false, consumer: "dashboard", supportsDashboardStream: manager.supportsActivities)
                    publishWidgetSnapshot()
                    WidgetSnapshotPublisher.shared.flush()
                case .active:
                    if isDashboardVisible {
                        fleet.setVisible(true, consumer: "dashboard", supportsDashboardStream: manager.supportsActivities)
                    }
                default:
                    break
                }
            }
            // Capabilities can resolve after authentication when the restore
            // request raced a transient network failure — start the stream
            // once the server is known to be v2.
            .onChange(of: manager.supportsActivities) { _, supported in
                if supported, isDashboardVisible {
                    fleet.setVisible(true, consumer: "dashboard", supportsDashboardStream: true)
                }
            }
            .onChange(of: historyMutationStore.latestClear) { _, event in
                guard let event else { return }
                failedActivities = ActivityHistoryClearFilter.retainingActiveActivities(
                    in: failedActivities,
                    clearedEnvironmentIDs: event.environmentIDs
                )
            }
        }
        .onChange(of: isNavigationRoot, initial: true) { _, isRoot in
            onNavigationRootChange(isRoot)
        }
    }

    // MARK: - Subviews

    /// First load with no data yet: placeholder cards instead of content.
    private var showsSkeleton: Bool {
        !hasLoadedOnce && isLoading
    }

    /// Only after an environments fetch succeeded and returned nothing.
    private var showsEmptyState: Bool {
        !showsSkeleton && environments.isEmpty && hasLoadedEnvironments
    }

    private var hasPinnedDashboardResources: Bool {
        !pinnedStore.pinnedIDs(kind: .container, envID: envID).isEmpty ||
            !pinnedStore.pinnedIDs(kind: .project, envID: envID).isEmpty
    }

    /// Dismisses the summary popover / center before running an item action.
    /// Presenting a sheet or pushing a route while another presentation is
    /// still animating out gets dropped by UIKit, hence the short wait.
    private func performAttentionAction(_ action: @escaping () -> Void) {
        showAttentionSummary = false
        showAttentionCenter = false
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            action()
        }
    }

    private var environmentColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 340), spacing: 12)]
    }

    private var environmentsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                DashboardSectionTitle("Environments")
                Spacer()
                if manager.currentUser?.isAdmin == true {
                    updateAllButton
                }
            }

            if streamStore.streamFailed, !streamStore.streamUnsupported {
                streamFailedBanner
            }

            if let liveStatsLimitPresentation {
                Text(liveStatsLimitPresentation.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: environmentColumns, alignment: .leading, spacing: 12) {
                ForEach(Array(environments.enumerated()), id: \.element.id) { index, env in
                    EnvironmentFleetListRow(
                        environment: env,
                        dockerInfo: fleet.dockerInfoByEnvironmentID[env.id],
                        actionItems: fleet.actionItemsByEnvironmentID[env.id],
                        streamState: streamStore.state(for: env.id),
                        series: statsHistory.series(for: env.id),
                        isActive: env.id == manager.activeEnvironmentID.rawValue,
                        onOpen: {
                            detailRoute = EnvironmentDetailRoute(id: env.id, name: env.name ?? env.id)
                        },
                        onRefresh: {
                            await refreshEnvironmentDockerInfo(environmentID: env.id)
                        }
                    )
                    // Cascade only the first screenful; later cards appear as
                    // they scroll in, faded by the edge transition instead.
                    .cardEntrance(id: "dashboard.environment.\(env.id)", index: min(index, 5) + 4)
                    .scrollEdgeFade()
                }
            }

            if environments.count < rawEnvironmentCount {
                ProgressView("Loading more environments…")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .id(environments.count)
                    .onAppear {
                        showNextEnvironmentBatch()
                    }
            }
        }
    }

    /// Environments whose dashboard snapshot reports a newer Arcane release.
    /// Nil until at least one snapshot has loaded (v1 servers never do), so
    /// the button stays enabled when the answer is unknown.
    private var arcaneUpgradeCount: Int? {
        let loaded = environments.compactMap { env -> Bool? in
            guard let state = streamStore.state(for: env.id), state.hasLoaded,
                  let info = state.snapshot?.versionInfo else { return nil }
            return info.updateAvailable
        }
        guard !loaded.isEmpty else { return nil }
        return loaded.filter { $0 }.count
    }

    /// Two-tap Update All. Resting: a compact capsule with the update icon and
    /// the number of environments that have an upgrade. Armed: grows into a
    /// red "Confirm Update" capsule. Confirming opens the sheet, which starts
    /// the run immediately. Disabled once the fleet is known to be current.
    /// Everything animates inside the capsule (no overlays), so the shape
    /// morph stays smooth.
    private var updateAllButton: some View {
        let upgrades = arcaneUpgradeCount
        let isUpToDate = upgrades == 0
        return Button {
            if isUpdateAllArmed {
                disarmUpdateAll()
                showUpdateAll = true
            } else {
                armUpdateAll()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isUpToDate ? "checkmark" : (isUpdateAllArmed ? "checkmark.circle.fill" : "arrow.up.circle.fill"))
                    .contentTransition(.symbolEffect(.replace))
                if isUpdateAllArmed {
                    Text("Confirm Update")
                        .fixedSize()
                        .transition(.opacity)
                } else if let upgrades, upgrades > 0 {
                    Text(verbatim: "\(upgrades)")
                        .monospacedDigit()
                        .fixedSize()
                        .transition(.opacity)
                }
            }
            .font(.subheadline.weight(.semibold))
            .frame(minWidth: 20)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(isUpdateAllArmed ? Color.red : Color.accentColor)
        .disabled(isUpToDate)
        .sensoryFeedback(.selection, trigger: isUpdateAllArmed)
        .onDisappear { disarmUpdateAll() }
        .accessibilityLabel(isUpToDate
            ? "All environments are up to date"
            : (isUpdateAllArmed
                ? "Confirm update of all environments"
                : "Update All\(upgrades.map { ", \($0) environments have upgrades" } ?? "")"))
        .accessibilityHint(isUpdateAllArmed ? "Starts updating every environment" : "Tap again to confirm")
    }

    private func armUpdateAll() {
        withAnimation(Motion.reduced(Motion.entrance, reduceMotion: reduceMotion)) {
            isUpdateAllArmed = true
        }
        updateAllDisarmTask?.cancel()
        updateAllDisarmTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.reduced(Motion.state, reduceMotion: reduceMotion)) {
                isUpdateAllArmed = false
            }
        }
    }

    private func disarmUpdateAll() {
        updateAllDisarmTask?.cancel()
        updateAllDisarmTask = nil
        withAnimation(Motion.reduced(Motion.state, reduceMotion: reduceMotion)) {
            isUpdateAllArmed = false
        }
    }

    /// Shown when the aggregated stream burned its whole reconnect budget;
    /// cards keep rendering last-known/legacy data underneath.
    private var streamFailedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Live counts paused")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Retry") { streamStore.retry() }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.standard, style: .continuous))
    }


    /// Triage rows for the Needs Attention card, folded from data the
    /// dashboard already holds — no extra fetches. Empty means all clear
    /// (the card simply doesn't render).
    private var needsAttentionItems: [NeedsAttentionItem] {
        var items: [NeedsAttentionItem] = []

        // Offline / erroring environments from the live stream states.
        let erroring = environments.filter { streamStore.state(for: $0.id)?.streamError == true }
        if let first = erroring.first {
            items.append(NeedsAttentionItem(
                id: "offline-environments",
                detail: "Live data is unavailable until the environment reconnects.",
                severity: .critical,
                icon: "wifi.exclamationmark",
                title: erroring.count == 1
                    ? "\(first.name ?? first.id) unreachable"
                    : "Environments unreachable",
                count: erroring.count,
                action: {
                    detailRoute = EnvironmentDetailRoute(id: first.id, name: first.name ?? first.id)
                }
            ))
        }

        // Fold server-computed action items across every environment snapshot.
        var stopped = 0, updates = 0, expiringKeys = 0
        var vulnerabilities = 0
        var vulnerabilityEnv: (id: String, name: String, count: Int)?
        var criticalVulns = false
        for env in environments {
            guard let state = streamStore.state(for: env.id), state.hasLoaded,
                  let snapshotItems = state.snapshot?.actionItems.items else { continue }
            for item in snapshotItems {
                switch item.kind {
                case .stoppedContainers: stopped += item.count
                case .imageUpdates: updates += item.count
                case .expiringKeys: expiringKeys += item.count
                case .actionableVulnerabilities:
                    vulnerabilities += item.count
                    if item.severity == .critical { criticalVulns = true }
                    if item.count > (vulnerabilityEnv?.count ?? 0) {
                        vulnerabilityEnv = (env.id, env.name ?? env.id, item.count)
                    }
                case .unknown: break
                }
            }
        }

        if vulnerabilities > 0, let target = vulnerabilityEnv {
            items.append(NeedsAttentionItem(
                id: "vulnerabilities",
                detail: "Open the vulnerability report for the most affected environment.",
                severity: criticalVulns ? .critical : .warning,
                icon: "exclamationmark.shield.fill",
                title: "Actionable vulnerabilities",
                count: vulnerabilities,
                action: {
                    vulnerabilityRoute = EnvironmentDetailRoute(id: target.id, name: target.name)
                }
            ))
        }
        if stopped > 0 {
            items.append(NeedsAttentionItem(
                id: "stopped-containers",
                detail: "Review containers that are not running.",
                severity: .warning,
                icon: "stop.fill",
                title: "Stopped containers",
                count: stopped,
                action: { selectedTab = AppTab.containers.id }
            ))
        }
        // Prefer the summary-based image count (same source as the Updates
        // tile) so this row, the tile, and the image list they both open all
        // agree. The server action item counts *resources* (a project with
        // several outdated images counts once), which reads as a mismatch.
        let imageUpdates = imageUpdatesTotal ?? updates
        if imageUpdates > 0 {
            items.append(NeedsAttentionItem(
                id: "image-updates",
                detail: "Newer images are available to pull.",
                severity: .warning,
                icon: "arrow.triangle.2.circlepath",
                title: "Image updates available",
                count: imageUpdates,
                action: { showImageUpdates = true }
            ))
        }
        if expiringKeys > 0 {
            items.append(NeedsAttentionItem(
                id: "expiring-keys",
                detail: "Rotate API keys before they expire.",
                severity: .warning,
                icon: "key.fill",
                title: "API keys expiring soon",
                count: expiringKeys,
                action: { showAPIKeys = true }
            ))
        }
        if !failedActivities.isEmpty {
            items.append(NeedsAttentionItem(
                id: "failed-activities",
                detail: "Open the Activity Center to inspect failures.",
                severity: .critical,
                icon: "exclamationmark.triangle.fill",
                title: "Failed activities",
                count: failedActivities.count,
                action: { quickActionRouter.openActivityCenter() }
            ))
        }
        return items
    }

    private var skeletonContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(0..<4, id: \.self) { _ in
                    skeletonTile
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .glassCardBackground()

            VStack(alignment: .leading, spacing: 12) {
                SkeletonRect(width: 150, height: 20)
                ForEach(0..<2, id: \.self) { _ in
                    skeletonEnvironmentCard
                }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .skeletonShimmer()
    }

    private var skeletonTile: some View {
        VStack(alignment: .leading, spacing: 6) {
            SkeletonRect(width: 44, height: 20)
            SkeletonRect(width: 56, height: 10, cornerRadius: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var skeletonEnvironmentCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonRect(width: 150, height: 16)
                    SkeletonRect(width: 90, height: 10, cornerRadius: 3)
                }
                Spacer()
                SkeletonCircle(size: 22)
            }
            HStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in
                    SkeletonRect(width: 56, height: 30)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack(spacing: 16) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 7) {
                        SkeletonCircle(size: 18)
                        SkeletonRect(width: 52, height: 12)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCardBackground()
    }

    private var overviewSection: some View {
        // Docker info is the only count source that includes every container.
        // A failed environment request invalidates the fleet total instead of
        // falling back to the dashboard snapshot's filtered count.
        let running: Int? = liveCounts?.running
        let total = liveCounts?.total
        let images = liveCounts?.images

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                DashboardStatTile(
                    title: "Updates",
                    value: imageUpdatesTotal.map { "\($0)" } ?? "—",
                    icon: "arrow.triangle.2.circlepath",
                    tint: .green
                ) { showImageUpdates = true }
                .cardEntrance(id: "dashboard.tile.updates", index: 0)
                DashboardStatTile(
                    title: "Containers",
                    value: running.flatMap { running in
                        total.map { "\(running) / \($0)" }
                    } ?? "—",
                    icon: "cube.box.fill",
                    tint: .orange
                ) { selectedTab = AppTab.containers.id }
                .cardEntrance(id: "dashboard.tile.containers", index: 1)
                DashboardStatTile(
                    title: "Images",
                    value: images.map { "\($0)" } ?? "—",
                    icon: "photo.stack.fill",
                    tint: .purple
                ) { selectedTab = AppTab.images.id }
                .cardEntrance(id: "dashboard.tile.images", index: 2)
                DashboardStatTile(
                    title: "Volumes",
                    value: volumesTotal.map { "\($0)" } ?? "—",
                    icon: "externaldrive.fill",
                    tint: .teal
                ) { showVolumes = true }
                .cardEntrance(id: "dashboard.tile.volumes", index: 3)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .glassCardBackground()
            .scrollEdgeFade()

            fleetCountAvailabilityNote
                .cardEntrance(id: "dashboard.overview.note", index: 4)
        }
    }

    /// Footnote under the overview panel (never inside it).
    @ViewBuilder
    private var fleetCountAvailabilityNote: some View {
        let issues = countAvailabilityIssues
        if issues.isEmpty {
            Label("Counts include all enabled environments.", systemImage: "server.rack")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        } else {
            Button {
                countAvailabilityPresentation = DashboardCountAvailability(issues: issues)
            } label: {
                Label("Some environment counts are unavailable.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            .accessibilityHint("Shows which environment counts could not be loaded")
            .popover(item: $countAvailabilityPresentation) { availability in
                DashboardCountAvailabilityPopover(issues: availability.issues)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }


    private var countAvailabilityIssues: [DashboardCountIssue] {
        guard hasLoadedFleetCounts else { return [] }
        var issues: [DashboardCountIssue] = []

        let dockerUnavailableIDs = allEnvironments
            .filter(\.enabled)
            .filter { environmentLiveStates[$0.id]?.dockerInfo == nil }
            .map(\.id)
        if liveCounts == nil, !dockerUnavailableIDs.isEmpty {
            issues.append(DashboardCountIssue(
                id: "docker",
                title: "Container and image counts",
                detail: "Docker information could not be loaded from \(environmentSummary(for: dockerUnavailableIDs))."
            ))
        }

        if !volumeCountUnavailableEnvironmentIDs.isEmpty {
            issues.append(DashboardCountIssue(
                id: "volumes",
                title: "Volume count",
                detail: "Volume totals could not be loaded from \(environmentSummary(for: volumeCountUnavailableEnvironmentIDs))."
            ))
        }

        if streamStore.aggregate == nil, !updateCountUnavailableEnvironmentIDs.isEmpty {
            issues.append(DashboardCountIssue(
                id: "updates",
                title: "Update count",
                detail: "Image update totals could not be loaded from \(environmentSummary(for: updateCountUnavailableEnvironmentIDs))."
            ))
        }

        return issues
    }

    private func environmentSummary(for ids: [String]) -> String {
        let namesByID = Dictionary(
            uniqueKeysWithValues: allEnvironments.map { ($0.id, $0.name ?? $0.id) }
        )
        let names = ids.map { namesByID[$0] ?? $0 }
        let visibleNames = names.prefix(2)
        let summary = visibleNames.joined(separator: visibleNames.count == 2 ? " and " : "")
        let remaining = names.count - visibleNames.count
        return remaining > 0 ? "\(summary) and \(remaining) more" : summary
    }

    // MARK: - Data loading

    private func refreshDashboard() async {
        // Reconnecting invalidates the live aggregate immediately. Preserve
        // its last successful update total until the replacement arrives.
        supplementalImageUpdatesTotal = imageUpdatesTotal
        streamStore.reconnect()
        statsHistory.reconnect()
        await loadData(refresh: true)
    }

    private func loadData(refresh: Bool = false) async {
        guard let client = manager.client else { return }
        if refresh { cardRefreshToken += 1 }
        if refresh || allEnvironments.isEmpty {
            visibleEnvironmentCount = Self.environmentBatchSize
        }
        // Match the container and image tiles: keep the last successful totals
        // visible while a refresh fetches their replacements. Initial loads
        // still begin without a value.
        if !refresh {
            volumesTotal = nil
            supplementalImageUpdatesTotal = nil
        }
        liveCounts = nil
        environmentLiveStates = [:]
        volumeCountUnavailableEnvironmentIDs = []
        updateCountUnavailableEnvironmentIDs = []
        hasLoadedFleetCounts = false
        if !hasLoadedOnce { isLoading = true }
        defer {
            isLoading = false
            // A cancelled first load (auth/env restore racing the task) must
            // not latch "loaded" — the empty/loaded branches would render
            // with no data until the next appear.
            if !Task.isCancelled { hasLoadedOnce = true }
        }

        async let envTask: [Arcane.Environment]? = loadEnvironmentsCached(refresh: refresh)
        let path = "dashboard/environments"
        async let rawReq = client.transport.rawRequest(path, body: Optional<String>.none)

        let envResult = await envTask
        if Task.isCancelled { return }
        let envs = envResult ?? []
        if envResult != nil { hasLoadedEnvironments = true }
        rawEnvironmentCount = envs.count
        allEnvironments = envs
        let visibleEnvironments = dashboardEnvironments(from: envs)
        environments = visibleEnvironments
        // The environment catalog is primary content. Publish it before
        // awaiting any fleet aggregate: one unreachable environment can make
        // those backend requests slow, but must not hold the whole Dashboard.
        // Those tiles show "—" until their totals arrive a moment later. The
        // `defer` still clears these on any early return as a safety net.
        hasLoadedOnce = true
        isLoading = false

        // Overview totals represent every environment, independent of how many
        // cards have been revealed so far.
        let enabledEnvironments = envs.filter(\.enabled)
        async let volumesResult = loadVolumesTotal(envs: enabledEnvironments)
        async let updatesResult = loadImageUpdatesTotal(envs: enabledEnvironments)
        let volumes = await volumesResult
        let updates = await updatesResult
        if !Task.isCancelled {
            if let total = volumes.total {
                volumesTotal = total
            }
            volumeCountUnavailableEnvironmentIDs = volumes.unavailableEnvironmentIDs
            if let total = updates.total {
                supplementalImageUpdatesTotal = total
            }
            updateCountUnavailableEnvironmentIDs = updates.unavailableEnvironmentIDs
            updateFleetLiveStateFromStore()
            hasLoadedFleetCounts = true
        }

        // Supplemental count requests must publish before the legacy overview
        // and dashboard snapshot refreshes, which can be slower or unsupported.
        let reqData = try? await rawReq
        if Task.isCancelled { return }
        if let reqData {
            overview = (try? JSONDecoder().decode(DashboardOverviewEnvelope.self, from: reqData))?.data
                ?? (try? JSONDecoder().decode(DashboardGlobalOverview.self, from: reqData))
        }
        if refresh, streamStore.isStreaming {
            await streamStore.refresh()
        }

        let clearSequence = historyMutationStore.latestClear?.sequence
        var activities = await loadFailedWork()
        if !Task.isCancelled {
            if let clearEvent = historyMutationStore.latestClear,
               clearEvent.sequence != clearSequence {
                activities = ActivityHistoryClearFilter.retainingActiveActivities(
                    in: activities,
                    clearedEnvironmentIDs: clearEvent.environmentIDs
                )
            }
            failedActivities = activities
        }
        publishWidgetSnapshot()
    }

    /// Fold the dashboard's current knowledge into the App-Group widget
    /// snapshot. Cheap to call; the publisher debounces the actual write.
    private func publishWidgetSnapshot() {
        guard manager.client != nil, hasLoadedEnvironments else { return }
        let allEnabledEnvironments = allEnvironments.filter(\.enabled)
        let enabledEnvironments = Array(
            allEnabledEnvironments.prefix(WidgetSnapshot.maximumEnvironments)
        )
        guard allEnabledEnvironments.allSatisfy({ environmentLiveStates[$0.id] != nil }) else { return }

        let previousByID = Dictionary(
            (WidgetSnapshotStore.load()?.environments ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let summaries: [WidgetSnapshot.EnvSummary] = enabledEnvironments.map { env in
            let state = streamStore.state(for: env.id)
            let snapshot = (state?.hasLoaded == true) ? state?.snapshot : nil
            let updates = snapshot?.actionItems.items
                .first(where: {
                    if case .imageUpdates = $0.kind { return true }
                    return false
                })?.count ?? previousByID[env.id]?.updatesAvailable ?? 0
            let vulnerabilities = snapshot?.actionItems.items
                .first(where: {
                    if case .actionableVulnerabilities = $0.kind { return true }
                    return false
                })?.count ?? previousByID[env.id]?.actionableVulnerabilities

            let info: DockerInfo?
            let online: Bool
            switch environmentLiveStates[env.id] {
            case .online(let dockerInfo):
                info = dockerInfo
                online = true
            case .offline, .none:
                info = nil
                online = false
            }
            return WidgetSnapshot.EnvSummary(
                id: env.id,
                name: env.name ?? env.id,
                online: online,
                running: Int(info?.containersRunning ?? 0),
                stopped: Int(info?.containersStopped ?? 0),
                total: Int(info?.containers ?? 0),
                images: Int(info?.images ?? 0),
                updatesAvailable: updates,
                actionableVulnerabilities: vulnerabilities
            )
        }
        WidgetSnapshotPublisher.shared.schedule(WidgetSnapshot(
            generatedAt: Date(),
            serverConfigured: true,
            serverOrigin: manager.parsedServerURL.flatMap(AppGroup.canonicalServerOrigin(for:)),
            isDemo: manager.isDemoActive,
            accentHex: UserDefaults.standard.string(forKey: "accentColorHex"),
            activeEnvironmentID: manager.activeEnvironmentID.rawValue,
            environments: summaries,
            suggestedContainers: []
        ))
    }

    private func loadFailedWork() async -> [Activity] {
        guard manager.supportsActivities, let client = manager.client else { return [] }

        let targets: [(id: EnvironmentID, name: String)] = allEnvironments.map { environment in
            let name = environment.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (
                id: EnvironmentID(rawValue: environment.id),
                name: name.isEmpty ? environment.id : name
            )
        }
        guard !targets.isEmpty else { return [] }

        var merged: [Activity] = []
        await withTaskGroup(of: [Activity].self) { group in
            for environment in targets {
                group.addTask {
                    let response = try? await client.activities.listPaginated(
                        envID: environment.id,
                        order: .descending,
                        start: 0,
                        limit: 3,
                        status: .failed
                    )
                    return (response?.data ?? []).map { activity in
                        var normalized = activity
                        if normalized.sourceEnvironmentID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                            normalized.sourceEnvironmentID = environment.id.rawValue
                        }
                        if normalized.sourceEnvironmentName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                            normalized.sourceEnvironmentName = environment.name
                        }
                        return normalized
                    }
                }
            }
            for await activities in group {
                merged.append(contentsOf: activities)
            }
        }

        return merged
            .sorted { lhs, rhs in
                return lhs.sortTime > rhs.sortTime
            }
            .prefix(3)
            .map { $0 }
    }

    private func loadVolumesTotal(envs: [Arcane.Environment]) async -> DashboardFleetCountResult {
        guard let client = manager.client else {
            return DashboardFleetCountResult(
                total: nil,
                unavailableEnvironmentIDs: envs.map(\.id)
            )
        }
        guard !envs.isEmpty else {
            return DashboardFleetCountResult(total: 0, unavailableEnvironmentIDs: [])
        }

        return await withTaskGroup(of: (String, Int64?).self) { group in
            var iterator = envs.makeIterator()
            let initialBatch = min(Self.maxConcurrentPerEnvFetches, envs.count)
            for _ in 0..<initialBatch {
                guard let env = iterator.next() else { break }
                let envID = EnvironmentID(rawValue: env.id)
                group.addTask {
                    (env.id, await Self.volumeCount(client: client, envID: envID))
                }
            }
            var counts: [String: Int64] = [:]
            for await (id, count) in group {
                if let count {
                    counts[id] = count
                }
                if let env = iterator.next() {
                    let envID = EnvironmentID(rawValue: env.id)
                    group.addTask {
                        (env.id, await Self.volumeCount(client: client, envID: envID))
                    }
                }
            }
            let unavailableIDs = envs.compactMap { counts[$0.id] == nil ? $0.id : nil }
            let total = unavailableIDs.isEmpty ? Int(counts.values.reduce(0, +)) : nil
            return DashboardFleetCountResult(
                total: total,
                unavailableEnvironmentIDs: unavailableIDs
            )
        }
    }

    private nonisolated static func volumeCount(client: ArcaneClient, envID: EnvironmentID) async -> Int64? {
        do {
            return Int64(try await client.volumes.counts(envID: envID).total)
        } catch is CancellationError {
            return nil
        } catch {
            // Older servers may not expose the dedicated counts route. The
            // paginated list still supplies the same unfiltered total.
        }
        let query = SearchPaginationSort(start: 0, limit: 1)
        return try? await client.volumes.list(envID: envID, query: query).pagination.totalItems
    }

    private func loadImageUpdatesTotal(envs: [Arcane.Environment]) async -> DashboardFleetCountResult {
        guard let client = manager.client else {
            return DashboardFleetCountResult(
                total: nil,
                unavailableEnvironmentIDs: envs.map(\.id)
            )
        }
        guard !envs.isEmpty else {
            return DashboardFleetCountResult(total: 0, unavailableEnvironmentIDs: [])
        }

        let counts = await withTaskGroup(of: (String, Int?).self) { group in
            var iterator = envs.makeIterator()
            let initialBatch = min(Self.maxConcurrentPerEnvFetches, envs.count)
            for _ in 0..<initialBatch {
                guard let env = iterator.next() else { break }
                let envID = EnvironmentID(rawValue: env.id)
                group.addTask {
                    let summary = try? await client.images.updateSummary(envID: envID)
                    return (envID.rawValue, summary?.imagesWithUpdates)
                }
            }
            var counts: [String: Int] = [:]
            for await result in group {
                if let count = result.1 {
                    counts[result.0] = count
                }
                if let env = iterator.next() {
                    let envID = EnvironmentID(rawValue: env.id)
                    group.addTask {
                        let summary = try? await client.images.updateSummary(envID: envID)
                        return (envID.rawValue, summary?.imagesWithUpdates)
                    }
                }
            }
            return counts
        }
        imageUpdateCountStore.setSummaryCounts(
            counts,
            client: manager.client,
            userID: manager.currentUser?.id
        )
        let unavailableIDs = envs.compactMap { counts[$0.id] == nil ? $0.id : nil }
        return DashboardFleetCountResult(
            total: unavailableIDs.isEmpty ? counts.values.reduce(0, +) : nil,
            unavailableEnvironmentIDs: unavailableIDs
        )
    }

    private func refreshLiveCounts() async {
        await fleet.refreshDockerInformation(client: manager.client)
        guard !Task.isCancelled else { return }
        updateFleetLiveStateFromStore()
    }

    private func aggregateLiveCounts(
        _ states: [String: DashboardEnvironmentLiveState],
        expectedCount: Int
    ) -> DashboardLiveCounts? {
        guard expectedCount > 0, states.count == expectedCount else { return nil }
        var aggregate = DashboardLiveCounts(running: 0, stopped: 0, total: 0, images: 0)
        for state in states.values {
            guard case .online(let info) = state else { return nil }
            aggregate.running += Int(info.containersRunning)
            aggregate.stopped += Int(info.containersStopped)
            aggregate.total += Int(info.containers)
            aggregate.images += Int(info.images)
        }
        return aggregate
    }

    private func refreshEnvironmentDockerInfo(environmentID: String) async {
        await fleet.refreshDockerInformation(for: environmentID, client: manager.client)
        updateFleetLiveStateFromStore()
    }

    private func updateFleetLiveStateFromStore() {
        let enabledEnvironments = allEnvironments.filter(\.enabled)
        environmentLiveStates = enabledEnvironments.reduce(into: [:]) { states, environment in
            if let info = fleet.dockerInfoByEnvironmentID[environment.id] {
                states[environment.id] = .online(info)
            } else {
                states[environment.id] = .offline
            }
        }
        liveCounts = aggregateLiveCounts(
            environmentLiveStates,
            expectedCount: enabledEnvironments.count
        )
        publishWidgetSnapshot()
    }

    /// Nil means the fetch failed (or no client yet) — distinct from a
    /// successful load of zero environments.
    private func loadEnvironmentsCached(refresh: Bool) async -> [Arcane.Environment]? {
        await fleet.load(manager: manager, refresh: refresh)
        guard fleet.hasLoaded else { return nil }
        let fresh = fleet.environments
        hasLoadedEnvironments = true
        rawEnvironmentCount = fresh.count
        allEnvironments = fresh
        environments = dashboardEnvironments(from: fresh)
        return fresh
    }

    private func updateEnvironmentCatalogFromStore() {
        guard fleet.hasLoaded else { return }
        let fresh = fleet.environments
        hasLoadedEnvironments = true
        rawEnvironmentCount = fresh.count
        allEnvironments = fresh
        environments = dashboardEnvironments(from: fresh)
        hasLoadedOnce = true
        isLoading = false
    }

    private func dashboardEnvironments(from envs: [Arcane.Environment]) -> [Arcane.Environment] {
        let activeID = manager.activeEnvironmentID.rawValue
        var ordered = envs
        if let activeIndex = ordered.firstIndex(where: { $0.id == activeID }) {
            let active = ordered.remove(at: activeIndex)
            ordered.insert(active, at: 0)
        }
        return Array(ordered.prefix(visibleEnvironmentCount))
    }

    private func showNextEnvironmentBatch() {
        guard environments.count < allEnvironments.count else { return }
        visibleEnvironmentCount = min(
            visibleEnvironmentCount + Self.environmentBatchSize,
            allEnvironments.count
        )
        environments = dashboardEnvironments(from: allEnvironments)
    }
}

nonisolated enum DashboardImageUpdateCountResolver {
    static func resolve(shared: Int?, streamed: Int?, supplemental: Int?) -> Int? {
        shared ?? streamed ?? supplemental
    }
}

/// Activity Center entry point. Failed work is surfaced by the Attention
/// Center, so this button carries no badge of its own.
private struct DashboardActivityToolbarButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "clock.arrow.circlepath")
                .appAccentToolbarSymbol()
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel("Activity Center")
    }
}

/// iOS 26 shows today's date under the large title; iOS 18 has no subtitle
/// slot on iPhone, so the title stands alone there.
private struct DashboardDateSubtitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.navigationSubtitle(
                Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
            )
        } else {
            content
        }
    }
}

// MARK: - Shared components (used across views)

/// Apple-Fitness-inspired progress ring with the current value at its center
/// and a label beneath. Used for the live CPU/Memory/Disk gauges in the hero.
struct StatRing: View {
    let value: Double
    let valueText: String
    let label: String
    let tint: Color
    var size: CGFloat = 78
    var lineWidth: CGFloat = 9
    var errorMessage: String?

    private var hasError: Bool {
        errorMessage?.isEmpty == false
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(.secondary.opacity(0.15), lineWidth: lineWidth)
                    .frame(width: size, height: size)
                SmoothProgressBar(progress: hasError ? 0 : value, tint: hasError ? .orange : tint, lineWidth: lineWidth)
                    .frame(width: size, height: size)
                if hasError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.orange)
                } else {
                    Text(valueText)
                        .font(.footnote.bold())
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .motionAwareAnimation(Motion.state, value: valueText)
                }
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(hasError ? .orange : .secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hasError ? "\(label): unavailable" : "\(label): \(valueText)")
        .accessibilityValue(hasError ? (errorMessage ?? "Live stats unavailable") : "\(Int(value * 100)) percent")
    }
}

/// One overview stat: rounded number over a caption with a tiny tinted glyph.
/// Four of these share the single-row overview panel; each is a button.
struct DashboardStatTile: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                    .motionAwareAnimation(Motion.state, value: value)
                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(tint)
                        .symbolEffect(.bounce, value: value)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .cardRowLinkStyle()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens \(title)")
    }
}

/// Section heading for dashboard groups (Pinned, Environments).
struct DashboardSectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .foregroundStyle(Color.primary)
    }
}

/// Symbol on a soft tint disc. Restrained — the tint sits at low opacity
/// behind a tinted glyph rather than a saturated fill.
struct DashboardRowIcon: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 30
    /// The glyph bounces whenever this changes (e.g. the tile's value).
    var changeToken: String = ""

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tint)
            .symbolEffect(.bounce, value: changeToken)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: Circle())
            .accessibilityHidden(true)
    }
}

/// Trailing disclosure chevron for button rows that act like navigation links.
struct DashboardRowChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

private struct DashboardCountAvailabilityPopover: View {
    let issues: [DashboardCountIssue]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Incomplete environment counts", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            ForEach(issues) { issue in
                VStack(alignment: .leading, spacing: 3) {
                    Text(issue.title)
                        .font(.subheadline.weight(.semibold))
                    Text(issue.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            Text("Pull down on the Dashboard to retry unavailable environments.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(idealWidth: 300, maxWidth: 340, alignment: .leading)
    }
}

struct DashboardTile: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    let action: () -> Void
    var body: some View {
        DashboardStatTile(title: title, value: value, icon: icon, tint: color, action: action)
    }
}

struct SmoothProgressBar: View {
    var progress: Double
    var tint: Color
    var lineWidth: CGFloat

    var body: some View {
        Circle()
            .trim(from: 0.0, to: CGFloat(min(progress, 1.0)))
            .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(Angle(degrees: -90))
            .animation(Motion.gauge, value: progress)
    }
}

struct DashboardMiniMetric: View {
    let title: String
    let value: String
    let color: Color
    var cornerRadius: CGFloat = Radius.nested

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.bold())
                .foregroundStyle(color)
                .contentTransition(.numericText())
                .motionAwareAnimation(Motion.state, value: value)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .raisedChipBackground(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
    }
}

struct DashboardInfoGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).padding(.leading, 4)
            VStack(spacing: 0) { content }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Radius.standard, style: .continuous))
        }
    }
}

struct DashboardInfoRow: View {
    let label: String
    let value: String
    var isLast = false

    init(label: String, value: String, isLast: Bool = false) {
        self.label = label
        self.value = value
        self.isLast = isLast
    }

    /// Convenience initializer for optional values. Nil/empty renders as "—".
    init(label: String, value: String?, isLast: Bool = false) {
        self.label = label
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.value = trimmed.isEmpty ? "—" : trimmed
        self.isLast = isLast
    }
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.subheadline)
        .padding(12)
        if !isLast { Divider().padding(.leading, 12) }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    var body: some View {
        DashboardTile(title: title, value: value, icon: icon, color: color, action: {})
    }
}

struct StatusBadge: View {
    let status: String?
    let isLive: Bool?

    init(status: String?, isLive: Bool? = nil) {
        self.status = status
        self.isLive = isLive
    }

    var body: some View {
        ResourceStatusBadge(status: status, isLive: isLive)
    }
}

// MARK: - Prune View

struct SystemPruneView: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager

    let environmentID: EnvironmentID

    @State private var containerMode: PruneContainerMode = .none
    @State private var containerAge = "24h"
    @State private var imageMode: PruneImageMode = .none
    @State private var imageAge = "24h"
    @State private var volumeMode: PruneVolumeMode = .none
    @State private var networkMode: PruneNetworkMode = .none
    @State private var networkAge = "24h"
    @State private var buildCacheMode: PruneBuildCacheMode = .none
    @State private var buildCacheAge = "24h"

    @State private var isPruning = false
    @State private var errorMessage: String?
    @State private var hasLoadedServerDefaults = false

    private var selectedCount: Int {
        var count = 0
        if containerMode != .none { count += 1 }
        if imageMode != .none { count += 1 }
        if volumeMode != .none { count += 1 }
        if networkMode != .none { count += 1 }
        if buildCacheMode != .none { count += 1 }
        return count
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Containers") {
                    FormPicker(title: "Containers", selection: $containerMode) {
                        Text("None").tag(PruneContainerMode.none)
                        Text("Stopped").tag(PruneContainerMode.stopped)
                        Text("Older than...").tag(PruneContainerMode.olderThan)
                    }
                    if containerMode == .olderThan { ageRow($containerAge) }
                }

                Section("Images") {
                    FormPicker(title: "Images", selection: $imageMode) {
                        Text("None").tag(PruneImageMode.none)
                        Text("Dangling").tag(PruneImageMode.dangling)
                        Text("All Unused").tag(PruneImageMode.all)
                        Text("Older than...").tag(PruneImageMode.olderThan)
                    }
                    if imageMode == .olderThan { ageRow($imageAge) }
                }

                Section("Volumes") {
                    FormPicker(title: "Volumes", selection: $volumeMode) {
                        Text("None").tag(PruneVolumeMode.none)
                        Text("Anonymous").tag(PruneVolumeMode.anonymous)
                        Text("All Unused").tag(PruneVolumeMode.all)
                    }
                }

                Section("Networks") {
                    FormPicker(title: "Networks", selection: $networkMode) {
                        Text("None").tag(PruneNetworkMode.none)
                        Text("Unused").tag(PruneNetworkMode.unused)
                        Text("Older than...").tag(PruneNetworkMode.olderThan)
                    }
                    if networkMode == .olderThan { ageRow($networkAge) }
                }

                Section("Build Cache") {
                    FormPicker(title: "Build Cache", selection: $buildCacheMode) {
                        Text("None").tag(PruneBuildCacheMode.none)
                        Text("Unused").tag(PruneBuildCacheMode.unused)
                        Text("All").tag(PruneBuildCacheMode.all)
                        Text("Older than...").tag(PruneBuildCacheMode.olderThan)
                    }
                    if buildCacheMode == .olderThan { ageRow($buildCacheAge) }
                }
            }
            .navigationTitle("System Prune")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isPruning {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button {
                            Task { await runPrune() }
                        } label: {
                            Label(
                                selectedCount > 0 ? "Prune (\(selectedCount))" : "Prune",
                                systemImage: "trash"
                            )
                        }
                        .disabled(selectedCount == 0)
                    }
                }
            }
            .alert("Prune failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task { await loadServerDefaults() }
        }
    }

    /// Seeds the pickers from the server's configured prune defaults — the
    /// same `prune*Mode`/`prune*Until` settings the web dialog uses. Best
    /// effort: on failure (older server, missing permission) the pickers just
    /// stay at "None".
    private func loadServerDefaults() async {
        guard !hasLoadedServerDefaults, let client = manager.client else { return }
        hasLoadedServerDefaults = true
        let path = client.rest.environmentPath(environmentID, "settings")
        guard let raw = try? await client.transport.rawRequest(path, body: Optional<String>.none),
              let dtos = try? JSONDecoder().decode([PublicSetting].self, from: raw) else { return }
        var dict: [String: String] = [:]
        for dto in dtos { dict[dto.key] = dto.value }

        // Server values use the same raw strings as the SDK enums
        // ("none" / "stopped" / "olderThan" / ...).
        if let mode = dict["pruneContainerMode"].flatMap(PruneContainerMode.init(rawValue:)) {
            containerMode = mode
        }
        if let until = dict["pruneContainerUntil"], !until.isEmpty { containerAge = until }
        if let mode = dict["pruneImageMode"].flatMap(PruneImageMode.init(rawValue:)) {
            imageMode = mode
        }
        if let until = dict["pruneImageUntil"], !until.isEmpty { imageAge = until }
        if let mode = dict["pruneVolumeMode"].flatMap(PruneVolumeMode.init(rawValue:)) {
            volumeMode = mode
        }
        if let mode = dict["pruneNetworkMode"].flatMap(PruneNetworkMode.init(rawValue:)) {
            networkMode = mode
        }
        if let until = dict["pruneNetworkUntil"], !until.isEmpty { networkAge = until }
        if let mode = dict["pruneBuildCacheMode"].flatMap(PruneBuildCacheMode.init(rawValue:)) {
            buildCacheMode = mode
        }
        if let until = dict["pruneBuildCacheUntil"], !until.isEmpty { buildCacheAge = until }
    }

    // MARK: - Form rows

    private func ageRow(_ binding: Binding<String>) -> some View {
        FormTextField(
            title: "Older Than",
            placeholder: "24h or 7d",
            text: binding,
            autocapitalization: .never,
            autocorrectionDisabled: true
        )
    }

    private func runPrune() async {
        guard let client = manager.client else { return }
        isPruning = true
        defer { isPruning = false }

        let request = PruneAllRequest(
            containers: containerMode != .none ? PruneContainersOptions(
                mode: containerMode,
                until: containerMode == .olderThan ? containerAge : nil
            ) : nil,
            images: imageMode != .none ? PruneImagesOptions(
                mode: imageMode,
                until: imageMode == .olderThan ? imageAge : nil
            ) : nil,
            volumes: volumeMode != .none ? PruneVolumesOptions(
                mode: volumeMode
            ) : nil,
            networks: networkMode != .none ? PruneNetworksOptions(
                mode: networkMode,
                until: networkMode == .olderThan ? networkAge : nil
            ) : nil,
            buildCache: buildCacheMode != .none ? PruneBuildCacheOptions(
                mode: buildCacheMode,
                until: buildCacheMode == .olderThan ? buildCacheAge : nil
            ) : nil
        )

        do {
            let result = try await client.system.prune(request, envID: environmentID)
            await ResponseCache.shared.invalidateEnvironment(environmentID.rawValue)
            if !manager.supportsActivities {
                showToast(.success(formatPruneResult(result)))
            }
            dismiss()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func friendlyErrorMessage(_ error: Error) -> String {
        return (error as? ArcaneError)?.localizedDescription ?? error.localizedDescription
    }

    private func formatPruneResult(_ result: PruneAllResult) -> String {
        var parts: [String] = []
        if let n = result.containersPruned?.count, n > 0 { parts.append("\(n) container\(n == 1 ? "" : "s")") }
        if let n = result.imagesDeleted?.count, n > 0 { parts.append("\(n) image\(n == 1 ? "" : "s")") }
        if let n = result.volumesDeleted?.count, n > 0 { parts.append("\(n) volume\(n == 1 ? "" : "s")") }
        if let n = result.networksDeleted?.count, n > 0 { parts.append("\(n) network\(n == 1 ? "" : "s")") }
        var summary = parts.isEmpty ? "Nothing to remove." : "Removed " + parts.joined(separator: ", ") + "."
        if result.spaceReclaimed > 0 {
            let space = Int64(result.spaceReclaimed)
            summary += " Freed \(space.byteString)."
        }
        if let errors = result.errors, !errors.isEmpty {
            summary += "\nErrors: " + errors.prefix(3).joined(separator: "; ")
        }
        return summary
    }
}
