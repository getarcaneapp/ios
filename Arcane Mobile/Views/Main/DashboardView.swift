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

struct DashboardView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @Binding var selectedTab: String
    
    @State private var environments: [ServerEnvironment] = []
    @State private var overview: DashboardGlobalOverview?
    @State private var volumesTotal: Int?
    @State private var imageUpdatesTotal: Int?
    @State private var rawEnvironmentCount: Int = 0
    @State private var detailRoute: EnvironmentDetailRoute?

    @State private var isLoading = false
    @State private var hasLoadedOnce = false
    @State private var showPruneSheet = false
    @State private var showVolumes = false

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
                        
                        environmentsSection
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
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
            .navigationDestination(item: $detailRoute) { route in
                SystemInfoDetailView(
                    environmentID: EnvironmentID(rawValue: route.id),
                    environmentName: route.name
                )
            }
            .task { await loadData() }
            .refreshable { await loadData(refresh: true) }
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
                    onSelect: {
                        detailRoute = EnvironmentDetailRoute(id: env.id, name: env.name ?? env.id)
                    }
                )
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
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 110, height: 14)
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
    }

    private var skeletonTile: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 32, height: 32)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 64, height: 18)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 80, height: 10)
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
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: 130, height: 14)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: 80, height: 10)
                }
                Spacer()
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 56, height: 20)
            }

            HStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { _ in
                    Spacer(minLength: 0)
                    VStack(spacing: 8) {
                        Circle()
                            .fill(Color.secondary.opacity(0.15))
                            .frame(width: 62, height: 62)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.18))
                            .frame(width: 36, height: 10)
                    }
                    Spacer(minLength: 0)
                }
            }

            Divider()

            HStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.18))
                            .frame(width: 30, height: 14)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.18))
                            .frame(width: 50, height: 10)
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
        let running = overview?.summary.containers?.runningContainers ?? 0
        let total = overview?.summary.containers?.totalContainers ?? 0
        let images = overview?.summary.imageUsageCounts?.totalImages ?? 0

        return Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                DashboardGlassTile(
                    title: "Updates",
                    value: imageUpdatesTotal.map { "\($0)" } ?? "—",
                    icon: "arrow.triangle.2.circlepath",
                    tint: .green
                ) { selectedTab = AppTab.updates.id }

                DashboardGlassTile(
                    title: "Containers",
                    value: total > 0 ? "\(running) / \(total)" : "—",
                    icon: "cube.box.fill",
                    tint: .orange
                ) { selectedTab = AppTab.containers.id }
            }
            GridRow {
                DashboardGlassTile(
                    title: "Images",
                    value: images > 0 ? "\(images)" : "—",
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
        if !hasLoadedOnce { isLoading = true }
        defer {
            isLoading = false
            hasLoadedOnce = true
        }

        async let envTask: [ServerEnvironment] = loadEnvironmentsCached(refresh: refresh)
        let path = "dashboard/environments"
        async let rawReq = client.transport.rawRequest(path, body: Optional<String>.none)

        let envs = await envTask
        let reqData = try? await rawReq

        if Task.isCancelled { return }
        rawEnvironmentCount = envs.count
        let bounded = Array(envs.prefix(Self.maxEnvironments))
        environments = bounded
        if let reqData {
            overview = (try? JSONDecoder().decode(DashboardOverviewEnvelope.self, from: reqData))?.data
                ?? (try? JSONDecoder().decode(DashboardGlobalOverview.self, from: reqData))
        }

        async let volumesResult = loadVolumesTotal(envs: bounded)
        async let updatesResult = loadImageUpdatesTotal(envs: bounded)
        let volumes = await volumesResult
        let updates = await updatesResult
        if !Task.isCancelled {
            volumesTotal = volumes
            imageUpdatesTotal = updates
        }
    }

    private func loadVolumesTotal(envs: [ServerEnvironment]) async -> Int {
        guard let client = manager.client else { return 0 }
        let online = envs.filter { $0.isOnline ?? false }
        guard !online.isEmpty else { return 0 }

        return await withTaskGroup(of: Int64.self) { group in
            var iterator = online.makeIterator()
            let initialBatch = min(Self.maxConcurrentPerEnvFetches, online.count)
            for _ in 0..<initialBatch {
                guard let env = iterator.next() else { break }
                let envID = EnvironmentID(rawValue: env.id)
                group.addTask {
                    (try? await client.listVolumesPage(envID: envID, start: 0, limit: 1).pagination.totalItems) ?? 0
                }
            }
            var total: Int64 = 0
            for await result in group {
                total += result
                if let env = iterator.next() {
                    let envID = EnvironmentID(rawValue: env.id)
                    group.addTask {
                        (try? await client.listVolumesPage(envID: envID, start: 0, limit: 1).pagination.totalItems) ?? 0
                    }
                }
            }
            return Int(total)
        }
    }

    private func loadImageUpdatesTotal(envs: [ServerEnvironment]) async -> Int {
        guard let client = manager.client else { return 0 }
        let online = envs.filter { $0.isOnline ?? false }
        guard !online.isEmpty else { return 0 }

        return await withTaskGroup(of: Int.self) { group in
            var iterator = online.makeIterator()
            let initialBatch = min(Self.maxConcurrentPerEnvFetches, online.count)
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

    private func loadEnvironmentsCached(refresh: Bool) async -> [ServerEnvironment] {
        guard let cached = manager.cached else { return [] }
        return (try? await cached.getListGlobal(
            "environments", elementType: ServerEnvironment.self,
            policy: .environments, refresh: refresh,
            onFresh: { fresh in
                rawEnvironmentCount = fresh.count
                environments = Array(fresh.prefix(Self.maxEnvironments))
            }
        )) ?? []
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

    @State private var animatedValue: Double = 0.0

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(.secondary.opacity(0.15), lineWidth: lineWidth)
                    .frame(width: size, height: size)
                SmoothProgressBar(progress: value, tint: tint, lineWidth: lineWidth)
                    .frame(width: size, height: size)
                Text(valueText)
                    .font(.footnote.bold())
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(valueText)")
        .accessibilityValue("\(Int(value * 100)) percent")
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
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
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
    var body: some View {
        Text(status ?? "UNKNOWN")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
    private var color: Color {
        let s = status?.lowercased() ?? ""
        if s == "running" || s == "online" { return .green }
        if s == "stopped" || s == "offline" { return .red }
        return .secondary
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

    @State private var containerMode = 0
    @State private var containerAge = "24h"
    @State private var imageMode = 0
    @State private var imageAge = "24h"
    @State private var volumeMode = 0
    @State private var networkMode = 0
    @State private var networkAge = "24h"
    @State private var buildCacheMode = 0
    @State private var buildCacheAge = "24h"

    @State private var isPruning = false
    @State private var errorMessage: String?
    @State private var resultMessage: String?

    private var selectedCount: Int {
        var count = 0
        if containerMode > 0 { count += 1 }
        if imageMode > 0 { count += 1 }
        if volumeMode > 0 { count += 1 }
        if networkMode > 0 { count += 1 }
        if buildCacheMode > 0 { count += 1 }
        return count
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Containers") {
                    Picker("Containers", selection: $containerMode) {
                        Text("None").tag(0)
                        Text("Stopped").tag(1)
                        Text("Older than...").tag(2)
                    }
                    if containerMode == 2 { ageRow($containerAge) }
                }

                Section("Images") {
                    Picker("Images", selection: $imageMode) {
                        Text("None").tag(0)
                        Text("Dangling (Unused)").tag(1)
                        Text("All Unused").tag(2)
                        Text("Older than...").tag(3)
                    }
                    if imageMode == 3 { ageRow($imageAge) }
                }

                Section("Volumes") {
                    Picker("Volumes", selection: $volumeMode) {
                        Text("None").tag(0)
                        Text("Anonymous Unused").tag(1)
                        Text("All Unused").tag(2)
                    }
                }

                Section("Networks") {
                    Picker("Networks", selection: $networkMode) {
                        Text("None").tag(0)
                        Text("Unused").tag(1)
                        Text("Older than...").tag(2)
                    }
                    if networkMode == 2 { ageRow($networkAge) }
                }

                Section("Build Cache") {
                    Picker("Build Cache", selection: $buildCacheMode) {
                        Text("None").tag(0)
                        Text("Unused").tag(1)
                        Text("All").tag(2)
                        Text("Older than...").tag(3)
                    }
                    if buildCacheMode == 3 { ageRow($buildCacheAge) }
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
            .alert("Prune complete", isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil; dismiss() } })) {
                Button("OK") { resultMessage = nil; dismiss() }
            } message: {
                Text(resultMessage ?? "")
            }
            .alert("Prune failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func ageRow(_ binding: Binding<String>) -> some View {
        HStack {
            Text("Older than")
                .foregroundStyle(.secondary)
            Spacer()
            TextField("e.g. 24h, 7d", text: binding)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(width: 100)
        }
    }

    private func runPrune() async {
        guard let client = manager.client else { return }
        isPruning = true
        defer { isPruning = false }

        let request = PruneAllRequest(
            containers: containerMode > 0 ? PruneContainersOptions(
                mode: containerMode == 1 ? "stopped" : "olderThan",
                until: containerMode == 2 ? containerAge : nil
            ) : nil,
            images: imageMode > 0 ? PruneImagesOptions(
                mode: imageMode == 1 ? "dangling" : (imageMode == 2 ? "all" : "olderThan"),
                until: imageMode == 3 ? imageAge : nil
            ) : nil,
            volumes: volumeMode > 0 ? PruneVolumesOptions(
                mode: volumeMode == 1 ? "anonymous" : "all"
            ) : nil,
            networks: networkMode > 0 ? PruneNetworksOptions(
                mode: networkMode == 1 ? "unused" : "olderThan",
                until: networkMode == 2 ? networkAge : nil
            ) : nil,
            buildCache: buildCacheMode > 0 ? PruneBuildCacheOptions(
                mode: buildCacheMode == 1 ? "unused" : (buildCacheMode == 2 ? "all" : "olderThan"),
                until: buildCacheMode == 3 ? buildCacheAge : nil
            ) : nil
        )

        do {
            let path = client.rest.environmentPath(environmentID, "system/prune")
            let result: PruneAllResult = try await client.rest.post(path, body: request)
            resultMessage = formatPruneResult(result)
            await ResponseCache.shared.invalidateEnvironment(environmentID.rawValue)
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
        if let space = result.spaceReclaimed, space > 0 {
            summary += " Freed \(space.byteString)."
        }
        if let errors = result.errors, !errors.isEmpty {
            summary += "\nErrors: " + errors.prefix(3).joined(separator: "; ")
        }
        return summary
    }
}