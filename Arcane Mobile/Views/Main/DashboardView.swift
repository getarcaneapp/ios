import SwiftUI
import UIKit
import Arcane

struct DashboardView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @Binding var selectedTab: Int
    @State private var dockerInfo: DockerInfo?
    @State private var environments: [ServerEnvironment] = []
    @State private var projectCount: Int?
    @State private var volumeCount: Int?
    @State private var volumeTotalBytes: Int64?
    @State private var isLoading = false
    @State private var hasLoadedOnce = false
    @State private var dockerError: String?
    @State private var showPruneSheet = false
    @State private var showVolumes = false
    @State private var latestStats: SystemStatsFrame?
    @State private var statsStreamTask: Task<Void, Never>?
    @State private var isStreaming = false

    private var envID: EnvironmentID { manager.activeEnvironmentID }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    if !hasLoadedOnce && isLoading {
                        ProgressView("Loading...")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    } else {
                        activeEnvironmentCard
                        if let error = dockerError {
                            dockerErrorBanner(error)
                        }
                        overviewGrid
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Dashboard")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    environmentMenu
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showPruneSheet = true } label: {
                        Image(systemName: "trash")
                    }
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
            .task { await loadData() }
            .task { startStatsStream() }
            .onDisappear {
                statsStreamTask?.cancel()
                statsStreamTask = nil
                isStreaming = false
            }
            .onChange(of: envID) { _, _ in restartStatsStream() }
            .refreshable { await loadData(refresh: true) }
        }
    }

    // MARK: - Subviews

    private var activeEnvironmentCard: some View {
        NavigationLink {
            SystemInfoDetailView(
                environmentID: envID,
                environmentName: manager.activeEnvironmentName
            )
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(systemName: "server.rack")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 48, height: 48)
                        .background(Color(uiColor: .tertiarySystemFill), in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(manager.activeEnvironmentName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        if let version = dockerInfo?.serverVersion {
                            Text("Docker \(version)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if dockerError != nil {
                            Text("Docker info unavailable")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()
                    StatusBadge(status: dockerError != nil ? "error" : (isLoading ? "loading" : "online"))
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 12) {
                    DashboardMiniMetric(title: "Running", value: metricValue(dockerInfo?.containersRunning), color: .green)
                    DashboardMiniMetric(title: "Stopped", value: metricValue(dockerInfo?.containersStopped), color: .secondary)
                    DashboardMiniMetric(title: "Images", value: metricValue(dockerInfo?.images), color: Color.accentColor)
                }
                .frame(maxWidth: .infinity)

                Divider()
                    .padding(.vertical, 4)

                resourceMetricRow(
                    label: "CPU",
                    icon: "cpu",
                    color: Color.accentColor,
                    percent: latestStats?.cpuPercent
                )
                resourceMetricRow(
                    label: "Memory",
                    icon: "memorychip",
                    color: Color.accentColor,
                    percent: memoryPercent
                )
                resourceMetricRow(
                    label: "Disk",
                    icon: "externaldrive",
                    color: Color.accentColor,
                    percent: diskPercent
                )
            }
            .padding(16)
            .dashboardCardBackground(cornerRadius: 18)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func resourceMetricRow(label: String, icon: String, color: Color, percent: Double?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 16)
            Text(label)
                .font(.subheadline)
                .frame(width: 60, alignment: .leading)
            SmoothProgressBar(value: clampedPercent(percent) / 100, tint: barTint(percent))
                .frame(height: 6)
            Text(percentString(percent))
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private var environmentMenu: some View {
        Menu {
            if environments.isEmpty {
                Text("No Environments")
            } else {
                ForEach(environments) { env in
                    let isOnline = env.isOnline ?? false
                    let isActive = env.id == manager.activeEnvironmentID.rawValue
                    Button {
                        manager.setActiveEnvironment(
                            id: EnvironmentID(rawValue: env.id),
                            name: env.name ?? env.id
                        )
                        Task { await loadDockerInfo() }
                    } label: {
                        Label(
                            env.name ?? env.id,
                            systemImage: isActive ? "checkmark.circle.fill" : "server.rack"
                        )
                    }
                    .disabled(!isOnline && !isActive)
                }
            }
        } label: {
            Image(systemName: "server.rack")
        }
    }

    private var overviewGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            let running = dockerInfo?.containersRunning ?? 0
            let total = dockerInfo?.containers ?? 0
            let stopped = dockerInfo?.containersStopped ?? 0
            let images = dockerInfo?.images ?? 0

            DashboardTile(
                title: "Containers",
                value: dockerInfo != nil ? "\(total)" : "--",
                subtitle: "\(running) running, \(stopped) stopped",
                icon: "cube.box.fill",
                color: Color.accentColor
            ) { selectedTab = 1 }

            DashboardTile(
                title: "Images",
                value: dockerInfo != nil ? "\(images)" : "--",
                subtitle: "Browse, pull, prune",
                icon: "photo.stack.fill",
                color: Color.accentColor
            ) { selectedTab = 2 }

            DashboardTile(
                title: "Projects",
                value: projectCount.map(String.init) ?? "--",
                subtitle: "Compose projects",
                icon: "square.stack.3d.up.fill",
                color: Color.accentColor
            ) { selectedTab = 3 }

            DashboardTile(
                title: "Volumes",
                value: volumeTotalBytes.map { $0.byteString } ?? "--",
                subtitle: volumeCount.map { "\($0) volume\($0 == 1 ? "" : "s")" } ?? "Persistent data",
                icon: "externaldrive.fill",
                color: Color.accentColor
            ) { showVolumes = true }
        }
    }

private func dockerErrorBanner(_ error: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.orange.opacity(0.18), lineWidth: 1)
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
        async let dockerTask: DockerInfo? = loadDockerInfoSilent(client: client, refresh: refresh)
        async let projectsTask: [Project] = loadProjectsCountCached(client: client, refresh: refresh)
        async let volumeSizesTask: [VolumeSizeInfo]? = loadVolumeSizesCached(client: client, refresh: refresh)

        let (envs, info, projects, volumeSizes) = await (envTask, dockerTask, projectsTask, volumeSizesTask)
        if Task.isCancelled { return }
        environments = envs
        dockerInfo = info
        projectCount = projects.count
        if let volumeSizes {
            volumeCount = volumeSizes.count
            volumeTotalBytes = volumeSizes.reduce(Int64(0)) { $0 + $1.size }
        }
    }

    private func loadEnvironmentsCached(refresh: Bool) async -> [ServerEnvironment] {
        guard let cached = manager.cached else { return [] }
        return (try? await cached.getGlobal(
            "environments", as: [ServerEnvironment].self,
            policy: .environments, refresh: refresh,
            onFresh: { fresh in environments = fresh }
        )) ?? []
    }

    private func loadProjectsCountCached(client: ArcaneClient, refresh: Bool) async -> [Project] {
        guard let cached = manager.cached else { return [] }
        let path = client.rest.environmentPath(envID, "projects")
        return (try? await cached.get(
            path, as: [Project].self, policy: .projects,
            envID: envID, refresh: refresh,
            onFresh: { fresh in projectCount = fresh.count }
        )) ?? []
    }

    private func loadVolumeSizesCached(client: ArcaneClient, refresh: Bool) async -> [VolumeSizeInfo]? {
        guard let cached = manager.cached else { return nil }
        let path = client.rest.environmentPath(envID, "volumes/sizes")
        return try? await cached.get(
            path, as: [VolumeSizeInfo].self, policy: .volumes,
            envID: envID, refresh: refresh,
            onFresh: { fresh in
                volumeCount = fresh.count
                volumeTotalBytes = fresh.reduce(Int64(0)) { $0 + $1.size }
            }
        )
    }

    private func loadDockerInfo() async {
        guard let client = manager.client else { return }
        dockerError = nil
        if let info = await loadDockerInfoSilent(client: client, refresh: true) {
            dockerInfo = info
        }
    }

    private func loadDockerInfoSilent(client: ArcaneClient, refresh: Bool = false) async -> DockerInfo? {
        let path = client.rest.environmentPath(envID, "system/docker/info")
        guard let cached = manager.cached else { return nil }
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
            await MainActor.run { dockerError = nil }
            return info
        } catch let error as ArcaneError {
            if Task.isCancelled || isCancellation(error) { return nil }
            await MainActor.run { dockerError = arcaneMessage(error) }
            return nil
        } catch {
            if Task.isCancelled || error is CancellationError { return nil }
            await MainActor.run { dockerError = "Docker info unavailable" }
            return nil
        }
    }

    private func isCancellation(_ error: ArcaneError) -> Bool {
        if case .transport(let msg) = error {
            return msg.lowercased().contains("cancel")
        }
        return false
    }

    private func arcaneMessage(_ error: ArcaneError) -> String {
        switch error {
        case .rateLimited: return "Docker info rate limited — try again shortly"
        case .notFound: return "Docker info not available for this environment"
        case .unauthorized, .forbidden: return "Not authorized to access Docker info"
        case .server(_, let msg): return msg
        case .transport(let msg): return "Connection error: \(msg)"
        case .decoding(let msg): return "Response error: \(msg)"
        default: return "Docker info unavailable"
        }
    }

    private func metricValue(_ value: (any BinaryInteger)?) -> String {
        guard dockerInfo != nil, let value else { return "--" }
        return "\(value)"
    }

    // MARK: - Stats streaming

    private func startStatsStream() {
        guard statsStreamTask == nil, let client = manager.client else { return }
        let stream = client.system.stats(envID: envID, interval: 2)
        isStreaming = true
        statsStreamTask = Task { @MainActor in
            do {
                for try await frame in stream {
                    if Task.isCancelled { break }
                    latestStats = frame
                }
            } catch is CancellationError {
            } catch {
            }
            isStreaming = false
        }
    }

    private func restartStatsStream() {
        statsStreamTask?.cancel()
        statsStreamTask = nil
        latestStats = nil
        startStatsStream()
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

// MARK: - Environment dashboard card

struct EnvironmentDashboardCard: View {
    let environment: ServerEnvironment
    var isActive: Bool = false
    var onSetActive: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.title3)
                .foregroundStyle(environment.isOnline ?? false ? .green : .secondary)
                .frame(width: 40, height: 40)
                .background(Color(uiColor: .tertiarySystemFill), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(environment.name ?? environment.id)
                    .font(.headline)
                if let url = environment.url {
                    Text(url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            } else if let onSetActive {
                Button("Use", action: onSetActive)
                    .font(.caption.bold())
                    .buttonStyle(.glass)
            }

            StatusBadge(status: environment.status)
        }
        .padding(14)
        .dashboardCardBackground(cornerRadius: 16)
    }
}

// MARK: - Shared components (used across views)

struct DashboardTile: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(color)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }

                Text(value)
                    .font(.title.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .padding(16)
            .dashboardCardBackground(cornerRadius: 18)
        }
        .buttonStyle(.plain)
    }
}

struct SmoothProgressBar: View {
    var value: Double
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(tint.opacity(0.18))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .animation(.smooth(duration: 1.2), value: value)
        .animation(.smooth(duration: 0.6), value: tint)
    }
}

struct DashboardMiniMetric: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline.bold())
                .foregroundStyle(color)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

extension View {
    func dashboardCardBackground(cornerRadius: CGFloat) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.18), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.06), radius: 10, x: 0, y: 4)
    }
}

struct DashboardInfoGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, 12)
            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color(uiColor: .separator).opacity(0.14), lineWidth: 0.5)
            }
        }
    }
}

struct DashboardInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .textSelection(.enabled)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.leading, 96)
                .opacity(0.55)
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            Text(value)
                .font(.title.bold())
                .foregroundStyle(.primary)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .dashboardCardBackground(cornerRadius: 18)
    }
}

struct StatusBadge: View {
    let status: String

    private var color: Color {
        switch status.lowercased() {
        case "online", "running", "up": return .green
        case "offline", "stopped", "down", "error": return .red
        case "partial", "partially running", "loading": return .orange
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(status.capitalized)
                .font(.caption.bold())
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
    }
}

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(title).font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}

// MARK: - System Prune Sheet

struct SystemPruneView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let environmentID: EnvironmentID

    // 0=none for all; each resource has its own levels
    @State private var containerMode = 0    // 0=none, 1=stopped, 2=olderThan
    @State private var containerAge = "24h"
    @State private var imageMode = 0        // 0=none, 1=danglingOnly, 2=allUnused, 3=olderThan
    @State private var imageAge = "24h"
    @State private var networkMode = 0      // 0=none, 1=unused, 2=olderThan
    @State private var networkAge = "24h"
    @State private var volumeMode = 0       // 0=none, 1=anonymousOnly, 2=allUnused
    @State private var buildCacheMode = 0   // 0=none, 1=unusedOnly, 2=allCache, 3=olderThan
    @State private var buildCacheAge = "24h"
    @State private var isPruning = false
    @State private var resultMessage: String?
    @State private var errorMessage: String?

    private var selectedCount: Int {
        [containerMode, imageMode, networkMode, volumeMode, buildCacheMode]
            .filter { $0 > 0 }.count
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Containers") {
                    Picker("Containers", selection: $containerMode) {
                        Text("None").tag(0)
                        Text("Stopped Containers").tag(1)
                        Text("Older Than...").tag(2)
                    }
                    .pickerStyle(.menu)
                    if containerMode == 2 { ageRow($containerAge) }
                }

                Section("Images") {
                    Picker("Images", selection: $imageMode) {
                        Text("None").tag(0)
                        Text("Dangling Only").tag(1)
                        Text("All Unused").tag(2)
                        Text("Older Than...").tag(3)
                    }
                    .pickerStyle(.menu)
                    if imageMode == 3 { ageRow($imageAge) }
                }

                Section("Networks") {
                    Picker("Networks", selection: $networkMode) {
                        Text("None").tag(0)
                        Text("Unused Networks").tag(1)
                        Text("Older Than...").tag(2)
                    }
                    .pickerStyle(.menu)
                    if networkMode == 2 { ageRow($networkAge) }
                }

                Section {
                    Picker("Volumes", selection: $volumeMode) {
                        Text("None").tag(0)
                        Text("Anonymous Only").tag(1)
                        Text("All Unused").tag(2)
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Volumes")
                } footer: {
                    Text("Only enable if you are certain no important data resides in unused volumes.")
                }

                Section("Build Cache") {
                    Picker("Build Cache", selection: $buildCacheMode) {
                        Text("None").tag(0)
                        Text("Unused Only").tag(1)
                        Text("All Cache").tag(2)
                        Text("Older Than...").tag(3)
                    }
                    .pickerStyle(.menu)
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
