import SwiftUI
import UIKit
import Arcane

struct DashboardView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @Binding var selectedTab: Int
    @State private var dockerInfo: DockerInfo?
    @State private var environments: [ServerEnvironment] = []
    @State private var projectCount: Int?
    @State private var isLoading = false
    @State private var dockerError: String?
    @State private var showPruneSheet = false
    @State private var showCreateProjectSheet = false
    @State private var showPullImageSheet = false
    @State private var showTemplateBrowser = false
    @State private var showVolumes = false
    @State private var showDockerDetails = false

    private var envID: EnvironmentID { manager.activeEnvironmentID }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    if isLoading && environments.isEmpty {
                        ProgressView("Loading...")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    } else {
                        activeEnvironmentCard
                        if let error = dockerError {
                            dockerErrorBanner(error)
                        }
                        overviewGrid
                        quickActions
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
                    Button { Task { await loadData() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
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
            .sheet(isPresented: $showCreateProjectSheet) {
                CreateProjectView(environmentID: envID) { await loadData() }
            }
            .sheet(isPresented: $showPullImageSheet) {
                PullImageView(environmentID: envID) { await loadData() }
            }
            .sheet(isPresented: $showTemplateBrowser) {
                TemplateBrowserView()
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
            .refreshable { await loadData() }
        }
    }

    // MARK: - Subviews

    private var activeEnvironmentCard: some View {
        Button {
            withAnimation(.snappy) {
                showDockerDetails.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(systemName: "server.rack")
                        .font(.title2)
                        .foregroundStyle(.blue)
                        .frame(width: 48, height: 48)
                        .background(Color(uiColor: .tertiarySystemFill), in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(manager.activeEnvironmentName)
                            .font(.headline)
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
                    Image(systemName: "chevron.down")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showDockerDetails ? 180 : 0))
                }

                HStack(spacing: 12) {
                    DashboardMiniMetric(title: "Running", value: metricValue(dockerInfo?.containersRunning), color: .green)
                    DashboardMiniMetric(title: "Stopped", value: metricValue(dockerInfo?.containersStopped), color: .secondary)
                    DashboardMiniMetric(title: "Images", value: metricValue(dockerInfo?.images), color: .purple)
                }

                if showDockerDetails {
                    Divider()
                        .padding(.top, 2)
                    dockerDetails
                }
            }
            .padding(16)
            .dashboardCardBackground(cornerRadius: 18)
        }
        .buttonStyle(.plain)
    }

    private var dockerDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            DashboardInfoGroup(title: "Host") {
                DashboardInfoRow(label: "Name", value: dockerInfo?.name ?? "--")
                DashboardInfoRow(label: "ID", value: dockerInfo?.id ?? "--")
                DashboardInfoRow(label: "OS", value: dockerInfo?.operatingSystem ?? "--")
                DashboardInfoRow(label: "Kernel", value: dockerInfo?.kernelVersion ?? "--")
                DashboardInfoRow(label: "Architecture", value: dockerInfo?.architecture ?? "--")
            }

            DashboardInfoGroup(title: "Engine") {
                DashboardInfoRow(label: "Docker Version", value: dockerInfo?.serverVersion ?? "--")
                DashboardInfoRow(label: "API Version", value: dockerInfo?.apiVersion ?? "--")
                DashboardInfoRow(label: "Go Version", value: dockerInfo?.goVersion ?? "--")
                DashboardInfoRow(label: "Git Commit", value: dockerInfo?.gitCommit ?? "--")
                DashboardInfoRow(label: "Build Time", value: dockerInfo?.buildTime ?? "--")
            }

            DashboardInfoGroup(title: "Resources") {
                DashboardInfoRow(label: "CPUs", value: metricValue(dockerInfo?.ncpu))
                DashboardInfoRow(label: "Memory", value: dockerInfo?.memTotal.byteString ?? "--")
                DashboardInfoRow(label: "Containers", value: metricValue(dockerInfo?.containers))
                DashboardInfoRow(label: "Paused", value: metricValue(dockerInfo?.containersPaused))
                DashboardInfoRow(label: "Images", value: metricValue(dockerInfo?.images))
            }

            DashboardInfoGroup(title: "Runtime") {
                DashboardInfoRow(label: "Storage Driver", value: dockerInfo?.driver ?? "--")
                DashboardInfoRow(label: "Logging Driver", value: dockerInfo?.loggingDriver ?? "--")
                DashboardInfoRow(label: "Cgroup Driver", value: dockerInfo?.cgroupDriver ?? "--")
                DashboardInfoRow(label: "Cgroup Version", value: dockerInfo?.cgroupVersion ?? "--")
                DashboardInfoRow(label: "Default Runtime", value: dockerInfo?.defaultRuntime ?? "--")
                DashboardInfoRow(label: "Runtimes", value: dockerInfo?.runtimes.additionalProperties.keys.sorted().joined(separator: ", ") ?? "--")
            }

            DashboardInfoGroup(title: "Features") {
                DashboardInfoRow(label: "Live Restore", value: boolValue(dockerInfo?.liveRestoreEnabled))
                DashboardInfoRow(label: "Experimental", value: boolValue(dockerInfo?.experimentalBuild))
                DashboardInfoRow(label: "Debug", value: boolValue(dockerInfo?.debug))
                DashboardInfoRow(label: "IPv4 Forwarding", value: boolValue(dockerInfo?.iPv4Forwarding))
                DashboardInfoRow(label: "Memory Limit", value: boolValue(dockerInfo?.memoryLimit))
                DashboardInfoRow(label: "Swap Limit", value: boolValue(dockerInfo?.swapLimit))
            }

            if let warnings = dockerInfo?.warnings, !warnings.isEmpty {
                DashboardInfoGroup(title: "Warnings") {
                    ForEach(warnings, id: \.self) { warning in
                        DashboardInfoRow(label: "Warning", value: warning)
                    }
                }
            }
        }
    }

    private var environmentMenu: some View {
        Menu {
            if environments.isEmpty {
                Text("No Environments")
            } else {
                ForEach(environments) { env in
                    Button {
                        manager.setActiveEnvironment(
                            id: EnvironmentID(rawValue: env.id),
                            name: env.name ?? env.id
                        )
                        Task { await loadDockerInfo() }
                    } label: {
                        Label(
                            env.name ?? env.id,
                            systemImage: env.id == manager.activeEnvironmentID.rawValue ? "checkmark.circle.fill" : "server.rack"
                        )
                    }
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
                color: .cyan
            ) { selectedTab = 1 }

            DashboardTile(
                title: "Images",
                value: dockerInfo != nil ? "\(images)" : "--",
                subtitle: "Browse, pull, prune",
                icon: "photo.stack.fill",
                color: .purple
            ) { selectedTab = 2 }

            DashboardTile(
                title: "Projects",
                value: projectCount.map(String.init) ?? "--",
                subtitle: "Compose projects",
                icon: "square.stack.3d.up.fill",
                color: .indigo
            ) { selectedTab = 3 }

            DashboardTile(
                title: "Volumes",
                value: "Storage",
                subtitle: "Persistent data",
                icon: "externaldrive.fill",
                color: .orange
            ) { showVolumes = true }
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Quick Actions", icon: "bolt.fill")
            HStack(spacing: 12) {
                DashboardActionButton(title: "New Project", icon: "plus.square.on.square", color: .indigo) {
                    showCreateProjectSheet = true
                }
                DashboardActionButton(title: "Pull Image", icon: "arrow.down.circle.fill", color: .purple) {
                    showPullImageSheet = true
                }
                DashboardActionButton(title: "Templates", icon: "doc.text.magnifyingglass", color: .blue) {
                    showTemplateBrowser = true
                }
            }
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

    private func loadData() async {
        guard let client = manager.client else { return }
        isLoading = true
        defer { isLoading = false }

        async let envTask: [ServerEnvironment] = (try? client.rest.get("environments")) ?? []
        async let dockerTask: DockerInfo? = loadDockerInfoSilent(client: client)
        async let projectsTask: [Project] = (try? client.rest.get(client.rest.environmentPath(envID, "projects"))) ?? []

        let (envs, info, projects) = await (envTask, dockerTask, projectsTask)
        environments = envs
        dockerInfo = info
        projectCount = projects.count
    }

    private func loadDockerInfo() async {
        guard let client = manager.client else { return }
        dockerError = nil
        if let info = await loadDockerInfoSilent(client: client) {
            dockerInfo = info
        }
    }

    private func loadDockerInfoSilent(client: ArcaneClient) async -> DockerInfo? {
        let path = client.rest.environmentPath(envID, "system/docker/info")
        do {
            let rawData = try await client.transport.rawRequest(path, body: Optional<String>.none)
            let info = try JSONDecoder().decode(DockerInfo.self, from: rawData)
            await MainActor.run { dockerError = nil }
            return info
        } catch let error as ArcaneError {
            await MainActor.run { dockerError = arcaneMessage(error) }
            return nil
        } catch {
            await MainActor.run { dockerError = "Docker info unavailable" }
            return nil
        }
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

    private func boolValue(_ value: Bool?) -> String {
        guard let value else { return "--" }
        return value ? "Yes" : "No"
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
                    .foregroundStyle(.blue)
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

struct DashboardMiniMetric: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline.bold())
                .foregroundStyle(color)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DashboardActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 76)
            .padding(.horizontal, 8)
            .dashboardCardBackground(cornerRadius: 16)
        }
        .buttonStyle(.plain)
    }
}

private extension View {
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

        if containerMode > 0 {
            let path = client.rest.environmentPath(environmentID, "containers/prune")
            let _: DataResponse<String>? = try? await client.rest.post(path, body: String?.none)
        }
        if imageMode > 0 {
            let path = client.rest.environmentPath(environmentID, "images/prune")
            let _: DataResponse<String>? = try? await client.rest.post(path, body: String?.none)
        }
        if networkMode > 0 {
            let path = client.rest.environmentPath(environmentID, "networks/prune")
            let _: DataResponse<String>? = try? await client.rest.post(path, body: String?.none)
        }
        if volumeMode > 0 {
            let path = client.rest.environmentPath(environmentID, "volumes/prune")
            let _: DataResponse<String>? = try? await client.rest.post(path, body: String?.none)
        }
        if buildCacheMode > 0 {
            let path = client.rest.environmentPath(environmentID, "build/prune")
            let _: DataResponse<String>? = try? await client.rest.post(path, body: String?.none)
        }
        dismiss()
    }
}
