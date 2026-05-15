import SwiftUI
import Arcane

struct SystemInfoDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let environmentID: EnvironmentID
    let environmentName: String

    @State private var dockerInfo: DockerInfo?
    @State private var versionInfo: VersionInfo?
    @State private var staticError: String?
    @State private var selectedTab: Tab = .docker

    enum Tab: String, CaseIterable, Identifiable {
        case docker = "Docker Info"
        case system = "System Info"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerCard

                Picker("", selection: $selectedTab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)

                if let info = dockerInfo {
                    Group {
                        switch selectedTab {
                        case .docker: dockerInfoTab(info)
                        case .system: systemInfoTab(info)
                        }
                    }
                    .transition(.opacity)
                } else if let staticError {
                    ErrorBanner(message: staticError, severity: .warning)
                } else {
                    HStack {
                        ProgressView()
                        Text("Loading…").foregroundStyle(.secondary)
                    }
                    .padding(.top, 40)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("System")
        .navigationBarTitleDisplayMode(.large)
        .task { await loadStatic() }
        .refreshable { await loadStatic() }
    }

    // MARK: - Header

    private var headerCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 48, height: 48)
                .background(Color(uiColor: .tertiarySystemFill), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(environmentName).font(.headline)
                if let version = dockerInfo?.serverVersion {
                    Text("Docker \(version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
            StatusBadge(status: staticError != nil ? "error" : "online")
        }
        .padding(16)
        .dashboardCardBackground(cornerRadius: 18)
    }

    // MARK: - Docker Info tab

    private func dockerInfoTab(_ info: DockerInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DashboardInfoGroup(title: "Engine") {
                DashboardInfoRow(label: "Server Version", value: info.serverVersion)
                DashboardInfoRow(label: "API Version", value: info.apiVersion)
                DashboardInfoRow(label: "Go Version", value: info.goVersion)
                DashboardInfoRow(label: "Git Commit", value: shortCommit(info.gitCommit))
                DashboardInfoRow(label: "Build Time", value: nonEmpty(info.buildTime))
            }

            DashboardInfoGroup(title: "Counts") {
                DashboardInfoRow(label: "Containers", value: "\(info.containers)")
                DashboardInfoRow(label: "Running", value: "\(info.containersRunning)")
                DashboardInfoRow(label: "Paused", value: "\(info.containersPaused)")
                DashboardInfoRow(label: "Stopped", value: "\(info.containersStopped)")
                DashboardInfoRow(label: "Images", value: "\(info.images)")
            }

            DashboardInfoGroup(title: "Runtime") {
                DashboardInfoRow(label: "Storage Driver", value: info.driver)
                DashboardInfoRow(label: "Logging Driver", value: info.loggingDriver)
                DashboardInfoRow(label: "Cgroup Driver", value: info.cgroupDriver)
                DashboardInfoRow(label: "Cgroup Version", value: info.cgroupVersion ?? "—")
                DashboardInfoRow(label: "Default Runtime", value: info.defaultRuntime)
                DashboardInfoRow(
                    label: "Runtimes",
                    value: info.runtimes.additionalProperties.keys.sorted().joined(separator: ", ").ifEmpty("—")
                )
                DashboardInfoRow(label: "Docker Root", value: info.dockerRootDir)
            }

            DashboardInfoGroup(title: "Features") {
                DashboardInfoRow(label: "Live Restore", value: boolText(info.liveRestoreEnabled))
                DashboardInfoRow(label: "Experimental", value: boolText(info.experimentalBuild))
                DashboardInfoRow(label: "Debug", value: boolText(info.debug))
                DashboardInfoRow(label: "IPv4 Forwarding", value: boolText(info.iPv4Forwarding))
                DashboardInfoRow(label: "Memory Limit", value: boolText(info.memoryLimit))
                DashboardInfoRow(label: "Swap Limit", value: boolText(info.swapLimit))
            }

            if let warnings = info.warnings, !warnings.isEmpty {
                DashboardInfoGroup(title: "Warnings") {
                    ForEach(warnings, id: \.self) { warning in
                        DashboardInfoRow(label: "Warning", value: warning)
                    }
                }
            }
        }
    }

    // MARK: - System Info tab

    private func systemInfoTab(_ info: DockerInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DashboardInfoGroup(title: "Host") {
                DashboardInfoRow(label: "Hostname", value: info.name)
                DashboardInfoRow(label: "Daemon ID", value: info.id)
                DashboardInfoRow(label: "Operating System", value: info.operatingSystem)
                DashboardInfoRow(label: "OS Type", value: info.osType)
                DashboardInfoRow(label: "Kernel", value: info.kernelVersion)
                DashboardInfoRow(label: "Architecture", value: info.architecture)
            }

            DashboardInfoGroup(title: "Capacity") {
                DashboardInfoRow(label: "CPUs", value: "\(info.ncpu)")
                DashboardInfoRow(label: "Memory", value: info.memTotal.byteString)
            }

            if let v = versionInfo {
                DashboardInfoGroup(title: "Arcane") {
                    DashboardInfoRow(label: "Version", value: v.displayVersion)
                    DashboardInfoRow(label: "Revision", value: nonEmpty(v.shortRevision))
                    DashboardInfoRow(label: "Go Version", value: nonEmpty(v.goVersion))
                    if let build = v.buildTime {
                        DashboardInfoRow(label: "Build Time", value: nonEmpty(build))
                    }
                    DashboardInfoRow(label: "Update Available", value: v.updateAvailable ? "Yes" : "No")
                    if v.updateAvailable, let newest = v.newestVersion {
                        DashboardInfoRow(label: "Newest Version", value: newest)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func loadStatic() async {
        guard let client = manager.client else { return }
        staticError = nil

        async let infoTask: DockerInfo? = {
            do {
                let path = client.rest.environmentPath(environmentID, "system/docker/info")
                let raw = try await client.transport.rawRequest(path, body: Optional<String>.none)
                return try JSONDecoder().decode(DockerInfo.self, from: raw)
            } catch {
                return nil
            }
        }()

        async let versionTask: VersionInfo? = {
            try? await client.system.appVersion()
        }()

        let (info, version) = await (infoTask, versionTask)

        if let info {
            dockerInfo = info
        } else if dockerInfo == nil {
            staticError = "Docker info unavailable"
        }
        if let version {
            versionInfo = version
        }
    }

    private func boolText(_ v: Bool?) -> String {
        guard let v else { return "—" }
        return v ? "Yes" : "No"
    }

    private func nonEmpty(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "—" }
        return s
    }

    private func shortCommit(_ commit: String) -> String {
        guard !commit.isEmpty else { return "—" }
        return String(commit.prefix(8))
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
