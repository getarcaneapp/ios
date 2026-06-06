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
/// `system/docker/info`, used as a version-independent source for the dashboard
/// tiles (v2 removed the cross-environment `/dashboard/environments` summary).
private struct DashboardLiveCounts: Sendable, Equatable {
    var running: Int
    var total: Int
    var images: Int
}

struct DashboardView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @Binding var selectedTab: String

    @Namespace private var heroTransition

    @State private var allEnvironments: [Arcane.Environment] = []
    @State private var environments: [Arcane.Environment] = []
    @State private var overview: DashboardGlobalOverview?
    @State private var volumesTotal: Int?
    @State private var imageUpdatesTotal: Int?
    @State private var liveCounts: DashboardLiveCounts?
    @State private var failedActivities: [Activity] = []
    @State private var rawEnvironmentCount: Int = 0
    @State private var detailRoute: EnvironmentDetailRoute?

    @State private var isLoading = false
    @State private var hasLoadedOnce = false
    /// Bumped on pull-to-refresh so per-environment cards force-refetch their own
    /// `system/docker/info` — their `.task` does not re-run on a parent refresh.
    @State private var cardRefreshToken = 0
    @State private var showPruneSheet = false
    @State private var showVolumes = false
    @State private var showImageUpdates = false
    @State private var showActivities = false

    private static let maxEnvironments = 50
    private static let maxConcurrentPerEnvFetches = 4

    private var envID: EnvironmentID { manager.activeEnvironmentID }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    dashboardHeader
                    if !hasLoadedOnce && isLoading {
                        skeletonView
                    } else {
                        overviewGrid

                        if manager.supportsActivities && !failedActivities.isEmpty {
                            DashboardFailedWorkCard(activities: failedActivities)
                        }

                        environmentsSection
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
            .softTopScrollEdgeEffectCompat()
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if manager.supportsActivities {
                        Button { showActivities = true } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .accessibilityLabel("Activity Center")
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showPruneSheet = true } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("System Prune")
                }
            }
            .sheet(isPresented: $showPruneSheet) {
                SystemPruneView(environmentID: envID)
            }
            .sheet(isPresented: $showVolumes) {
                NavigationStack {
                    VolumesView(
                        environmentID: envID,
                        environmentName: manager.activeEnvironmentName
                    )
                }
            }
            .sheet(isPresented: $showImageUpdates) {
                NavigationStack {
                    AllEnvironmentsImageUpdatesView()
                }
            }
            .sheet(isPresented: $showActivities) {
                NavigationStack {
                    ActivitiesView()
                }
            }
            .navigationDestination(item: $detailRoute) { route in
                SystemInfoDetailView(
                    environmentID: EnvironmentID(rawValue: route.id),
                    environmentName: route.name
                )
                .navigationTransition(.zoom(sourceID: route.id, in: heroTransition))
            }
            .task { await loadData() }
            .refreshable { await loadData(refresh: true) }
            .onChange(of: manager.activeEnvironmentID.rawValue) {
                environments = dashboardEnvironments(from: allEnvironments.isEmpty ? environments : allEnvironments)
            }
        }
    }

    // MARK: - Subviews

    private var environmentsSection: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            Text("Environments")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            ForEach(environments) { env in
                let cardData = overview?.environments?.first(where: { $0.id == env.id })
                EnvironmentDashboardCard(
                    environment: env,
                    cachedCard: cardData,
                    refreshToken: cardRefreshToken,
                    onSelect: {
                        detailRoute = EnvironmentDetailRoute(id: env.id, name: env.name ?? env.id)
                    }
                )
                .matchedTransitionSource(id: env.id, in: heroTransition)
                .padding(.bottom, 4)
            }

            if rawEnvironmentCount > Self.maxEnvironments {
                truncationFooter
            }
        }
    }

    private var truncationFooter: some View {
        NavigationLink {
            EnvironmentsView()
        } label: {
            Text("Showing \(Self.maxEnvironments) of \(rawEnvironmentCount) environments. Tap to see all.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.top, 4)
        }
        .buttonStyle(.plain)
    }

    private var dashboardHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Dashboard")
                .font(.system(.title, design: .default).bold())
                .foregroundStyle(.primary)
            Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var skeletonView: some View {
        VStack(spacing: 16) {
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    skeletonTile
                    skeletonTile
                }
                GridRow {
                    skeletonTile
                    skeletonTile
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                SkeletonRect(width: 110, height: 14)
                    .padding(.horizontal, 4)

                ForEach(0..<2, id: \.self) { _ in
                    skeletonEnvironmentCard
                        .padding(.bottom, 4)
                }
            }
            .padding(.top, 8)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .skeletonShimmer()
    }

    private var skeletonTile: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SkeletonCircle(size: 32)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                SkeletonRect(width: 64, height: 18)
                SkeletonRect(width: 80, height: 10, cornerRadius: 3)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCardBackground(cornerRadius: 16)
    }

    private var skeletonEnvironmentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonRect(width: 130, height: 14)
                    SkeletonRect(width: 80, height: 10, cornerRadius: 3)
                }
                Spacer()
                SkeletonFill(shape: Capsule())
                    .frame(width: 56, height: 20)
            }

            HStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { _ in
                    Spacer(minLength: 0)
                    VStack(spacing: 8) {
                        SkeletonCircle(size: 62)
                        SkeletonRect(width: 36, height: 10, cornerRadius: 2)
                    }
                    Spacer(minLength: 0)
                }
            }

            Divider()

            HStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in
                    VStack(spacing: 4) {
                        SkeletonRect(width: 30, height: 14)
                        SkeletonRect(width: 50, height: 10, cornerRadius: 3)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCardBackground(cornerRadius: 20)
    }

    private var overviewGrid: some View {
        // Prefer live per-environment Docker counts (from `system/docker/info`,
        // present on both v1 and v2 and not gated on reported online status);
        // fall back to the v1-only `/dashboard/environments` summary when present.
        // v2 removed that cross-environment endpoint, which is why these tiles
        // showed "—" against a 2.0 server. A loaded zero now renders as "0 / 0"/"0";
        // "—" means only "not loaded yet".
        let running = liveCounts?.running ?? overview?.summary.containers?.runningContainers ?? 0
        let total: Int? = liveCounts?.total ?? overview?.summary.containers?.totalContainers
        let images: Int? = liveCounts?.images ?? overview?.summary.imageUsageCounts?.totalImages

        return Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                DashboardGlassTile(
                    title: "Updates",
                    value: imageUpdatesTotal.map { "\($0)" } ?? "—",
                    icon: "arrow.triangle.2.circlepath",
                    tint: .green
                ) { showImageUpdates = true }

                DashboardGlassTile(
                    title: "Containers",
                    value: total.map { "\(running) / \($0)" } ?? "—",
                    icon: "cube.box.fill",
                    tint: .orange
                ) { selectedTab = AppTab.containers.id }
            }
            GridRow {
                DashboardGlassTile(
                    title: "Images",
                    value: images.map { "\($0)" } ?? "—",
                    icon: "photo.stack.fill",
                    tint: .purple
                ) { selectedTab = AppTab.images.id }

                DashboardGlassTile(
                    title: "Volumes",
                    value: volumesTotal.map { "\($0)" } ?? "—",
                    icon: "externaldrive.fill",
                    tint: .teal
                ) { showVolumes = true }
            }
        }
    }

    // MARK: - Data loading

    private func loadData(refresh: Bool = false) async {
        guard let client = manager.client else { return }
        if refresh { cardRefreshToken += 1 }
        if !hasLoadedOnce { isLoading = true }
        defer {
            isLoading = false
            hasLoadedOnce = true
        }

        async let envTask: [Arcane.Environment] = loadEnvironmentsCached(refresh: refresh)
        let path = "dashboard/environments"
        async let rawReq = client.transport.rawRequest(path, body: Optional<String>.none)

        let envs = await envTask
        let reqData = try? await rawReq

        if Task.isCancelled { return }
        rawEnvironmentCount = envs.count
        allEnvironments = envs
        let bounded = dashboardEnvironments(from: envs)
        environments = bounded
        if let reqData {
            overview = (try? JSONDecoder().decode(DashboardOverviewEnvelope.self, from: reqData))?.data
                ?? (try? JSONDecoder().decode(DashboardGlobalOverview.self, from: reqData))
        }

        // Primary content (environment cards + overview) is ready — dismiss the
        // skeleton now so the dashboard renders immediately instead of waiting
        // on the slower cross-environment Volumes/Updates aggregation below.
        // Those tiles show "—" until their totals arrive a moment later. The
        // `defer` still clears these on any early return as a safety net.
        hasLoadedOnce = true
        isLoading = false

        async let volumesResult = loadVolumesTotal(envs: bounded)
        async let updatesResult = loadImageUpdatesTotal(envs: bounded)
        async let countsResult = loadLiveCounts(envs: bounded, refresh: refresh)
        let volumes = await volumesResult
        let updates = await updatesResult
        let counts = await countsResult
        if !Task.isCancelled {
            volumesTotal = volumes
            imageUpdatesTotal = updates
            if let counts { liveCounts = counts }
        }

        let activities = await loadFailedWork()
        if !Task.isCancelled {
            failedActivities = activities
        }
    }

    private func loadFailedWork() async -> [Activity] {
        guard manager.supportsActivities, let client = manager.client else { return [] }

        let envResponse = try? await client.environments.list(
            query: SearchPaginationSort(start: 0, limit: 100, sortOrder: .ascending)
        )
        let targets: [(id: EnvironmentID, name: String)] = (envResponse?.data ?? []).map { environment in
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
                        limit: 20
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
            .filter { activity in
                activity.status == .failed
            }
            .sorted { lhs, rhs in
                return lhs.sortTime > rhs.sortTime
            }
            .prefix(3)
            .map { $0 }
    }

    private func loadVolumesTotal(envs: [Arcane.Environment]) async -> Int {
        guard let client = manager.client else { return 0 }
        guard !envs.isEmpty else { return 0 }

        return await withTaskGroup(of: Int64.self) { group in
            var iterator = envs.makeIterator()
            let initialBatch = min(Self.maxConcurrentPerEnvFetches, envs.count)
            for _ in 0..<initialBatch {
                guard let env = iterator.next() else { break }
                let envID = EnvironmentID(rawValue: env.id)
                group.addTask {
                    await Self.volumeCount(client: client, envID: envID)
                }
            }
            var total: Int64 = 0
            for await result in group {
                total += result
                if let env = iterator.next() {
                    let envID = EnvironmentID(rawValue: env.id)
                    group.addTask {
                        await Self.volumeCount(client: client, envID: envID)
                    }
                }
            }
            return Int(total)
        }
    }

    private nonisolated static func volumeCount(client: ArcaneClient, envID: EnvironmentID) async -> Int64 {
        let query = SearchPaginationSort(start: 0, limit: 1)
        return (try? await client.volumes.list(envID: envID, query: query).pagination.totalItems) ?? 0
    }

    private func loadImageUpdatesTotal(envs: [Arcane.Environment]) async -> Int {
        guard let client = manager.client else { return 0 }
        guard !envs.isEmpty else { return 0 }

        return await withTaskGroup(of: Int.self) { group in
            var iterator = envs.makeIterator()
            let initialBatch = min(Self.maxConcurrentPerEnvFetches, envs.count)
            for _ in 0..<initialBatch {
                guard let env = iterator.next() else { break }
                let envID = EnvironmentID(rawValue: env.id)
                group.addTask {
                    let path = client.rest.environmentPath(envID, "image-updates/summary")
                    let summary: ImageUpdateSummary? = try? await client.rest.get(path)
                    return summary?.imagesWithUpdates ?? 0
                }
            }
            var total = 0
            for await result in group {
                total += result
                if let env = iterator.next() {
                    let envID = EnvironmentID(rawValue: env.id)
                    group.addTask {
                        let path = client.rest.environmentPath(envID, "image-updates/summary")
                        let summary: ImageUpdateSummary? = try? await client.rest.get(path)
                        return summary?.imagesWithUpdates ?? 0
                    }
                }
            }
            return total
        }
    }

    /// Aggregates running/total container and image counts across environments
    /// from each environment's `system/docker/info` — the same cached source the
    /// environment cards use. Works on both v1 and v2 servers and does not rely
    /// on the cross-environment `/dashboard/environments` summary that v2 removed.
    /// Returns nil only when no environment's Docker info could be read, so the
    /// tiles can tell "not loaded" apart from a genuine zero.
    private func loadLiveCounts(envs: [Arcane.Environment], refresh: Bool) async -> DashboardLiveCounts? {
        guard let client = manager.client, let cached = manager.cached, !envs.isEmpty else { return nil }

        let perEnv: [DashboardLiveCounts] = await withTaskGroup(of: DashboardLiveCounts?.self) { group in
            var iterator = envs.makeIterator()
            let initialBatch = min(Self.maxConcurrentPerEnvFetches, envs.count)
            for _ in 0..<initialBatch {
                guard let env = iterator.next() else { break }
                let envID = EnvironmentID(rawValue: env.id)
                group.addTask { await Self.dockerCounts(client: client, cached: cached, envID: envID, refresh: refresh) }
            }
            var acc: [DashboardLiveCounts] = []
            for await result in group {
                if let result { acc.append(result) }
                if let env = iterator.next() {
                    let envID = EnvironmentID(rawValue: env.id)
                    group.addTask { await Self.dockerCounts(client: client, cached: cached, envID: envID, refresh: refresh) }
                }
            }
            return acc
        }

        guard !perEnv.isEmpty else { return nil }
        return perEnv.reduce(into: DashboardLiveCounts(running: 0, total: 0, images: 0)) {
            $0.running += $1.running
            $0.total += $1.total
            $0.images += $1.images
        }
    }

    private static func dockerCounts(
        client: ArcaneClient,
        cached: CachedClient,
        envID: EnvironmentID,
        refresh: Bool
    ) async -> DashboardLiveCounts? {
        let path = client.rest.environmentPath(envID, "system/docker/info")
        let fetcher: @Sendable () async throws -> DockerInfo = {
            let raw = try await client.transport.rawRequest(path, body: Optional<String>.none)
            return try JSONDecoder().decode(DockerInfo.self, from: raw)
        }
        guard let info = try? await cached.getCustom(
            path: path, as: DockerInfo.self, policy: .dockerInfo,
            envID: envID, refresh: refresh, fetcher: fetcher
        ) else { return nil }
        return DashboardLiveCounts(
            running: Int(info.containersRunning),
            total: Int(info.containers),
            images: Int(info.images)
        )
    }

    private func loadEnvironmentsCached(refresh: Bool) async -> [Arcane.Environment] {
        guard let cached = manager.cached else { return [] }
        return (try? await cached.getListGlobal(
            "environments", elementType: Arcane.Environment.self,
            policy: .environments, refresh: refresh,
            onFresh: { fresh in
                rawEnvironmentCount = fresh.count
                allEnvironments = fresh
                environments = dashboardEnvironments(from: fresh)
            }
        )) ?? []
    }

    private func dashboardEnvironments(from envs: [Arcane.Environment]) -> [Arcane.Environment] {
        let activeID = manager.activeEnvironmentID.rawValue
        var ordered = envs
        if let activeIndex = ordered.firstIndex(where: { $0.id == activeID }) {
            let active = ordered.remove(at: activeIndex)
            ordered.insert(active, at: 0)
        }
        return Array(ordered.prefix(Self.maxEnvironments))
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

    @State private var animatedValue: Double = 0.0

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
                        .motionAwareAnimation(.smooth(duration: 0.3), value: valueText)
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

struct DashboardGlassTile: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ZStack {
                        Circle()
                            .fill(tint)
                            .frame(width: 32, height: 32)
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary.opacity(0.5))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(value)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .foregroundStyle(.primary)
                        .minimumScaleFactor(0.8)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                        .motionAwareAnimation(.smooth(duration: 0.35), value: value)
                    Text(title)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dashboardCardBackground(cornerRadius: 16)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens \(title)")
    }
}

struct DashboardFailedWorkCard: View {
    let activities: [Activity]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 32, height: 32)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Failed Work")
                        .font(.headline)
                    Text("\(activities.count) failure\(activities.count == 1 ? "" : "s") need attention")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Failed Work, \(activities.count) failures need attention")

            VStack(spacing: 8) {
                ForEach(activities.prefix(3)) { activity in
                    NavigationLink {
                        ActivityDetailView(activity: activity)
                    } label: {
                        DashboardFailedWorkRow(activity: activity)
                    }
                    .buttonStyle(.plain)
                    .contentShape(.rect)
                    .accessibilityHint("Opens this failed activity")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCardBackground(cornerRadius: 16)
    }
}

private struct DashboardFailedWorkRow: View {
    let activity: Activity

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(activity.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(activity.latestMessage.isEmpty ? activity.subtitle : activity.latestMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(activity.status.rawValue.capitalized)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)

            Image(systemName: "chevron.right")
                .font(.caption2.bold())
                .foregroundStyle(.secondary.opacity(0.5))
                .accessibilityHidden(true)
        }
    }

    private var tint: Color {
        switch activity.status {
        case .failed: return .red
        case .running: return .blue
        case .queued: return .orange
        default: return .secondary
        }
    }
}

struct DashboardTile: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    let action: () -> Void
    var body: some View {
        DashboardGlassTile(title: title, value: value, icon: icon, tint: color, action: action)
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
            .animation(.spring(response: 0.8, dampingFraction: 0.7), value: progress)
    }
}

struct DashboardMiniMetric: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.bold())
                .foregroundStyle(color)
                .contentTransition(.numericText())
                .motionAwareAnimation(.smooth(duration: 0.3), value: value)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
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
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
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

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title).font(.title2.bold()).padding(.top, 10).padding(.bottom, 2)
    }
}

// MARK: - View Modifiers

extension View {
    func dashboardCardBackground(cornerRadius: CGFloat = 12) -> some View {
        self.modifier(DashboardCardBackgroundModifier(cornerRadius: cornerRadius))
    }
}

struct DashboardCardBackgroundModifier: ViewModifier {
    let cornerRadius: CGFloat
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                )
        } else {
            content
                .background(
                    Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
        }
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
        }
    }

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
            showToast(.success(formatPruneResult(result)))
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
