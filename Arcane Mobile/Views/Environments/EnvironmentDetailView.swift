import Arcane
import SwiftUI

struct EnvironmentDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(EnvironmentsStore.self) private var environmentsStore
    @SwiftUI.Environment(\.scenePhase) private var scenePhase
    let environmentID: EnvironmentID
    let environmentName: String

    @State private var dockerInfo: DockerInfo?
    @State private var versionInfo: EnvironmentVersion?
    @State private var details: EnvironmentDetails?
    @State private var staticError: String?
    @State private var environmentError: String?
    @State private var versionError: String?
    @State private var isLoading = false
    @State private var selectedTab: EnvironmentDetailSection
    @State private var securitySection = EnvironmentSecuritySection.scanning
    @State private var draft: EnvironmentSettingsDraft
    @State private var showsUpgrade = false

    init(environmentID: EnvironmentID, environmentName: String) {
        self.environmentID = environmentID
        self.environmentName = environmentName
        _selectedTab = State(initialValue: environmentID == .localDocker ? .info : .connection)
        _draft = State(
            initialValue: EnvironmentSettingsDraft(environmentID: environmentID, environmentName: environmentName))
    }

    private var environment: Arcane.Environment? {
        details?.environment ?? environmentsStore.environments.first { $0.id == environmentID.rawValue }
    }

    /// Mirrors the web's environment tabs: settings tabs need the environment
    /// enabled and settings access; the local environment has no connection.
    private var sections: [EnvironmentDetailSection] {
        let showsSettings =
            environment?.enabled != false && manager.permissions.has("settings:read", in: environmentID)
        return EnvironmentDetailSection.allCases.filter { section in
            switch section {
            case .connection: environmentID != .localDocker
            case .features, .storage, .docker, .security, .automations: showsSettings
            case .info, .gitOps: true
            }
        }
    }

    private var canEditSettings: Bool {
        manager.permissions.has("settings:write", in: environmentID)
    }

    private var allSettingsFields: [SettingFieldDef] {
        (environmentFeatureSections + environmentStorageSections + environmentDockerSections
            + EnvironmentSecuritySection.allCases.flatMap(\.sections) + environmentAutomationSections)
            .flatMap(\.fields)
    }

    var body: some View {
        List {
            Section {
                headerCard
                ScrollableTabBar(
                    selection: $selectedTab,
                    options: sections.map {
                        ScrollableTabOption(
                            $0,
                            title: $0.rawValue,
                            systemImage: $0.systemImage,
                            tint: .accentColor
                        )
                    },
                    accessibilityLabel: "Environment detail sections"
                )
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)

            tabContent
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(16)
        .navigationTitle(environment?.name ?? environmentName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if manager.currentUser?.isAdmin == true {
                AppToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Upgrade Arcane", systemImage: "arrow.up.circle") { showsUpgrade = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .appAccentToolbarSymbol()
                    }
                    .accessibilityLabel("More options")
                }
            }
        }
        .navigationDestination(isPresented: $showsUpgrade) {
            SystemUpgradeView(environmentID: environmentID, environmentName: environment?.name ?? environmentName)
        }
        .settingsSaveBar(
            isPresented: selectedTab.isSettings || draft.hasChanges,
            hasChanges: draft.hasChanges,
            isSaving: draft.isSaving,
            canSave: canEditSettings,
            isInteractionDisabled: draft.isLoading,
            onSave: { Task { await saveSettings() } },
            onRevert: draft.revert
        )
        .task(id: "\(manager.clientGeneration)|\(environmentID.rawValue)|\(scenePhase)") {
            guard scenePhase == .active else { return }
            isLoading = false
            details = nil
            dockerInfo = nil
            versionInfo = nil
            environmentError = nil
            staticError = nil
            versionError = nil
            await loadStatic()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await loadEnvironment()
            }
        }
        .task(id: selectedTab) {
            if !sections.contains(selectedTab), let first = sections.first { selectedTab = first }
            if selectedTab.isSettings, !draft.hasLoaded { await loadSettings() }
        }
        .refreshable {
            await loadStatic()
            if selectedTab.isSettings { await loadSettings() }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .info:
            flatRow {
                if let info = dockerInfo {
                    VStack(alignment: .leading, spacing: 12) {
                        systemInfoTab(info)
                        dockerInfoTab(info)
                    }
                } else if staticError == nil {
                    ArcaneLoadingView("Loading system information…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
                if let staticError {
                    ErrorBanner(message: staticError, severity: .warning)
                }
                if let versionError {
                    ErrorBanner(message: versionError, severity: .warning)
                }
            }
        case .connection:
            flatRow {
                if let environment {
                    EnvironmentConnectionView(
                        environment: environment,
                        details: details,
                        managerURL: manager.serverURL,
                        isAvailable: environmentError == nil
                    )
                } else if isLoading {
                    ArcaneLoadingView("Loading connection details…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
                if let environmentError {
                    ErrorBanner(message: environmentError, severity: .warning)
                }
            }
        case .features:
            settingsContent(environmentFeatureSections)
        case .storage:
            settingsContent(environmentStorageSections)
        case .docker:
            settingsContent(environmentDockerSections)
        case .security:
            Section {
                Picker("Security", selection: $securitySection) {
                    ForEach(EnvironmentSecuritySection.allCases) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            settingsContent(securitySection.sections)
        case .automations:
            settingsContent(environmentAutomationSections)
            Section {
                NavigationLink {
                    JobScheduleConfigView(environmentID: environmentID, environmentName: environment?.name)
                } label: {
                    Label("Schedules", systemImage: "clock.arrow.2.circlepath")
                }
            } footer: {
                Text("How often each job runs.")
            }
        case .gitOps:
            Section {
                NavigationLink {
                    GitOpsSyncsView(environmentID: environmentID)
                } label: {
                    Label("GitOps Syncs", systemImage: "arrow.triangle.merge")
                }
            } footer: {
                Text("Projects kept in sync with Git repositories in this environment.")
            }
        }
    }

    /// Settings tab sections, or a placeholder while they load or when the
    /// environment can't be reached.
    @ViewBuilder
    private func settingsContent(_ sections: [SettingsSectionDef]) -> some View {
        if draft.hasLoaded {
            SettingsSectionsView(sections: sections, draft: draft)
                .disabled(!canEditSettings)
            if let error = draft.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
        } else {
            flatRow {
                if let error = draft.errorMessage {
                    ErrorBanner(message: error, severity: .warning)
                } else {
                    ArcaneLoadingView("Loading settings…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
        }
    }

    /// Full-width content without the grouped-row background.
    private func flatRow(@ViewBuilder _ content: () -> some View) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) { content() }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
    }

    private func loadSettings() async {
        guard let client = manager.client else { return }
        await draft.load(client: client, fields: allSettingsFields)
    }

    private func saveSettings() async {
        guard let client = manager.client else { return }
        if await draft.save(client: client, fields: allSettingsFields) {
            showToast(.success("Settings saved"))
        }
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
                Text(environment?.name ?? environmentName).font(.headline)
                if let versionInfo {
                    Text("Arcane \(versionInfo.displayVersion)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                } else {
                    Text(versionError == nil ? "Checking version…" : "Version unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
            StatusBadge(
                status: environmentError != nil
                    ? "unavailable" : environment?.enabled == false ? "disabled" : environment?.status
            )
        }
        .padding(.vertical, 12)
    }

    // MARK: - Docker Info tab

    private func dockerInfoTab(_ info: DockerInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DashboardInfoGroup(title: "Engine", usesCardBackground: false) {
                DashboardInfoRow(label: "Server Version", value: info.serverVersion)
                DashboardInfoRow(label: "API Version", value: info.apiVersion)
                DashboardInfoRow(label: "Go Version", value: info.goVersion)
                DashboardInfoRow(label: "Git Commit", value: shortCommit(info.gitCommit))
                DashboardInfoRow(label: "Build Time", value: nonEmpty(info.buildTime))
            }

            DashboardInfoGroup(title: "Counts", usesCardBackground: false) {
                DashboardInfoRow(label: "Containers", value: "\(info.containers)")
                DashboardInfoRow(label: "Running", value: "\(info.containersRunning)")
                DashboardInfoRow(label: "Paused", value: "\(info.containersPaused)")
                DashboardInfoRow(label: "Stopped", value: "\(info.containersStopped)")
                DashboardInfoRow(label: "Images", value: "\(info.images)")
            }

            DashboardInfoGroup(title: "Runtime", usesCardBackground: false) {
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

            DashboardInfoGroup(title: "Features", usesCardBackground: false) {
                DashboardInfoRow(label: "Live Restore", value: boolText(info.liveRestoreEnabled))
                DashboardInfoRow(label: "Experimental", value: boolText(info.experimentalBuild))
                DashboardInfoRow(label: "Debug", value: boolText(info.debug))
                DashboardInfoRow(label: "IPv4 Forwarding", value: boolText(info.iPv4Forwarding))
                DashboardInfoRow(label: "Memory Limit", value: boolText(info.memoryLimit))
                DashboardInfoRow(label: "Swap Limit", value: boolText(info.swapLimit))
            }

            if let warnings = info.warnings, !warnings.isEmpty {
                DashboardInfoGroup(title: "Warnings", usesCardBackground: false) {
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
            DashboardInfoGroup(title: "Host", usesCardBackground: false) {
                DashboardInfoRow(label: "Hostname", value: info.name)
                DashboardInfoRow(label: "Daemon ID", value: info.id)
                DashboardInfoRow(label: "Operating System", value: info.operatingSystem)
                DashboardInfoRow(label: "OS Type", value: info.osType)
                DashboardInfoRow(label: "Kernel", value: info.kernelVersion)
                DashboardInfoRow(label: "Architecture", value: info.architecture)
            }

            DashboardInfoGroup(title: "Capacity", usesCardBackground: false) {
                DashboardInfoRow(label: "CPUs", value: info.ncpu.map { "\($0)" })
                DashboardInfoRow(label: "Memory", value: info.memTotal?.byteString)
            }

            if let v = versionInfo {
                DashboardInfoGroup(title: "Arcane", usesCardBackground: false) {
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
        guard let client = manager.client, !isLoading else { return }
        let generation = manager.clientGeneration
        isLoading = true
        defer { if generation == manager.clientGeneration { isLoading = false } }

        async let environmentTask: Void = loadEnvironment()
        async let infoTask: DockerInfo? = try? await RemoteDataLimits.boundedDockerInfo(
            client: client, environmentID: environmentID)
        async let versionTask: EnvironmentVersion? = try? await client.environments.version(id: environmentID)
        let (_, info, version) = await (environmentTask, infoTask, versionTask)
        guard !Task.isCancelled, generation == manager.clientGeneration else { return }

        if let info {
            dockerInfo = info
            staticError = nil
        } else {
            staticError = "Docker information could not be refreshed. Pull to refresh to retry."
        }
        if let version {
            versionInfo = version
            versionError = nil
        } else {
            versionError = "Arcane version unavailable for this environment."
        }
    }

    private func loadEnvironment() async {
        guard let client = manager.client else { return }
        let generation = manager.clientGeneration
        do {
            let loaded = try await RemoteDataLimits.boundedAPIResponse(
                client: client,
                path: "environments/\(ArcaneAPIHelpers.escapedPathComponent(environmentID.rawValue))",
                as: EnvironmentDetails.self
            )
            guard !Task.isCancelled, generation == manager.clientGeneration else { return }
            details = loaded
            environmentError = nil
        } catch {
            guard !Task.isCancelled, generation == manager.clientGeneration else { return }
            environmentError = "Connection details could not be refreshed. Pull to refresh to retry."
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

extension String {
    fileprivate func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
