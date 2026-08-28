import SwiftUI
import Arcane

// MARK: - Settings Category Definitions

struct SettingFieldDef: Identifiable {
    let key: String
    let label: String
    let type: SettingFieldType
    var description: String? = nil
    var minValue: Int? = nil
    var maxValue: Int? = nil
    /// Force the stacked (caption-above-field) layout for long free-text values
    /// like URLs, paths, and comma-separated lists. Short values stay inline.
    var stacked: Bool = false
    var visibleWhen: SettingFieldCondition? = nil
    var id: String { key }
}

struct SettingFieldCondition {
    let key: String
    let value: String
}

enum SettingFieldType {
    case text
    case number
    case boolean
    case password
    case select([String])
    case networkSelect
    case cron
    case textarea
    /// Multi-select checklist of running containers → comma-separated names.
    case containerMultiSelect
}

struct SettingsCategoryDef: Identifiable {
    let id: String
    let title: String
    let icon: String
    let summary: String
    let sections: [SettingsSectionDef]

    var fields: [SettingFieldDef] {
        sections.flatMap(\.fields)
    }
}

struct SettingsSectionDef: Identifiable {
    let id: String
    let title: String
    let fields: [SettingFieldDef]
}

let environmentConfigurationCategories: [SettingsCategoryDef] = [
    .init(
        id: "storage-limits",
        title: "Storage & Limits",
        icon: "externaldrive",
        summary: "Directories, storage paths, sync, and upload limits",
        sections: [
            .init(
                id: "directories-storage-paths",
                title: "Directories & Storage Paths",
                fields: [
                    .init(key: "projectsDirectory", label: "Projects Directory", type: .text, stacked: true),
                    .init(key: "templatesDirectory", label: "Templates Directory", type: .text, stacked: true),
                    .init(key: "swarmStackSourcesDirectory", label: "Swarm Stack Sources", type: .text, stacked: true),
                    .init(key: "diskUsagePath", label: "Disk Usage Path", type: .text, stacked: true),
                    .init(key: "followProjectSymlinks", label: "Follow Project Symlinks", type: .boolean),
                ]
            ),
            .init(
                id: "sync-upload-limits",
                title: "Sync & Upload Limits",
                fields: [
                    .init(key: "maxImageUploadSize", label: "Max Image Upload (MB)", type: .number),
                    .init(key: "gitSyncMaxFiles", label: "Git Sync Max Files", type: .number),
                    .init(key: "gitSyncMaxTotalSizeMb", label: "Git Sync Total Size (MB)", type: .number),
                    .init(key: "gitSyncMaxBinarySizeMb", label: "Git Sync Binary Size (MB)", type: .number),
                ]
            ),
        ]
    ),
    .init(
        id: "docker",
        title: "Docker Settings",
        icon: "shippingbox",
        summary: "Shell, deployment defaults, and resource pruning",
        sections: [
            .init(
                id: "configuration",
                title: "Configuration",
                fields: [
                    .init(key: "baseServerUrl", label: "Base Server URL", type: .text, stacked: true),
                    .init(key: "defaultShell", label: "Default Shell", type: .text),
                    .init(key: "defaultDeployPullPolicy", label: "Default Pull Policy", type: .select(["missing", "always", "never"])),
                    .init(key: "autoInjectEnv", label: "Auto-Inject .env", type: .boolean),
                ]
            ),
            .init(
                id: "prune-options",
                title: "Prune Options",
                fields: [
                    .init(key: "pruneContainerMode", label: "Prune Containers", type: .select(["none", "stopped", "olderThan"])),
                    .init(
                        key: "pruneContainerUntil",
                        label: "Container Age Filter",
                        type: .text,
                        visibleWhen: .init(key: "pruneContainerMode", value: "olderThan")
                    ),
                    .init(key: "pruneImageMode", label: "Prune Images", type: .select(["none", "dangling", "all", "olderThan"])),
                    .init(
                        key: "pruneImageUntil",
                        label: "Image Age Filter",
                        type: .text,
                        visibleWhen: .init(key: "pruneImageMode", value: "olderThan")
                    ),
                    .init(key: "pruneVolumeMode", label: "Prune Volumes", type: .select(["none", "anonymous", "all"])),
                    .init(key: "pruneNetworkMode", label: "Prune Networks", type: .select(["none", "unused", "olderThan"])),
                    .init(
                        key: "pruneNetworkUntil",
                        label: "Network Age Filter",
                        type: .text,
                        visibleWhen: .init(key: "pruneNetworkMode", value: "olderThan")
                    ),
                    .init(key: "pruneBuildCacheMode", label: "Prune Build Cache", type: .select(["none", "unused", "all", "olderThan"])),
                    .init(
                        key: "pruneBuildCacheUntil",
                        label: "Build Cache Age Filter",
                        type: .text,
                        visibleWhen: .init(key: "pruneBuildCacheMode", value: "olderThan")
                    ),
                ]
            ),
        ]
    ),
    .init(
        id: "security",
        title: "Security",
        icon: "shield.lefthalf.filled",
        summary: "Trivy vulnerability scanner configuration",
        sections: [
            .init(
                id: "vulnerability-scanning",
                title: "Vulnerability Scanning",
                fields: [
                    .init(key: "trivyImage", label: "Trivy Image", type: .text, stacked: true),
                    .init(
                        key: "trivyNetwork",
                        label: "Trivy Network",
                        type: .networkSelect,
                        description: "Auto inherits Arcane's network. Choose a built-in or custom Docker network to override it."
                    ),
                    .init(key: "trivySecurityOpts", label: "Security Options", type: .textarea),
                    .init(key: "trivyPrivileged", label: "Privileged Mode", type: .boolean),
                    .init(key: "trivyResourceLimitsEnabled", label: "Resource Limits", type: .boolean),
                    .init(key: "trivyCpuLimit", label: "CPU Limit", type: .text),
                    .init(key: "trivyMemoryLimitMb", label: "Memory Limit (MB)", type: .number),
                    .init(key: "trivyConcurrentScanContainers", label: "Concurrent Scans", type: .number, minValue: 1),
                    .init(key: "trivyPreserveCacheOnVolumePrune", label: "Preserve Cache", type: .boolean),
                    .init(key: "trivyConfig", label: "Trivy Config (YAML)", type: .textarea),
                    .init(key: "trivyIgnore", label: ".trivyignore", type: .textarea),
                ]
            ),
        ]
    ),
    .init(
        id: "automations",
        title: "Automations",
        icon: "calendar.badge.clock",
        summary: "Updates, monitoring, maintenance, and scheduled scans",
        sections: [
            .init(
                id: "updates",
                title: "Updates",
                fields: [
                    .init(key: "pollingEnabled", label: "Image Polling", type: .boolean),
                    .init(key: "pollingInterval", label: "Polling Interval", type: .cron),
                    .init(key: "autoUpdate", label: "Auto-Update", type: .boolean),
                    .init(key: "autoUpdateInterval", label: "Update Interval", type: .cron),
                    .init(key: "autoUpdateExcludedContainers", label: "Excluded Containers", type: .containerMultiSelect),
                ]
            ),
            .init(
                id: "monitoring",
                title: "Monitoring",
                fields: [
                    .init(key: "autoHealEnabled", label: "Auto-Heal", type: .boolean),
                    .init(key: "autoHealInterval", label: "Check Interval", type: .cron),
                    .init(key: "autoHealMaxRestarts", label: "Max Restarts", type: .number),
                    .init(key: "autoHealRestartWindow", label: "Restart Window (min)", type: .number),
                    .init(key: "autoHealExcludedContainers", label: "Excluded Containers", type: .containerMultiSelect),
                ]
            ),
            .init(
                id: "maintenance",
                title: "Maintenance",
                fields: [
                    .init(key: "scheduledPruneEnabled", label: "Scheduled Pruning", type: .boolean),
                    .init(key: "scheduledPruneInterval", label: "Prune Interval", type: .cron),
                    .init(key: "environmentHealthInterval", label: "Environment Health Check", type: .cron),
                    .init(key: "dockerClientRefreshInterval", label: "Docker Client Refresh", type: .cron),
                    .init(key: "eventCleanupInterval", label: "Event Cleanup", type: .cron),
                    .init(key: "expiredSessionsCleanupInterval", label: "Expired Sessions Cleanup", type: .cron),
                ]
            ),
            .init(
                id: "security",
                title: "Security",
                fields: [
                    .init(key: "vulnerabilityScanEnabled", label: "Vulnerability Scanning", type: .boolean),
                    .init(key: "vulnerabilityScanInterval", label: "Scan Interval", type: .cron),
                ]
            ),
        ]
    ),
]

let environmentServiceCategories: [SettingsCategoryDef] = [
    .init(
        id: "activity",
        title: "Activity",
        icon: "list.bullet.rectangle",
        summary: "Activity Center history retention",
        sections: [
            .init(
                id: "activity-history",
                title: "Activity History",
                fields: [
                    .init(key: "activityHistoryRetentionDays", label: "Retention (days)", type: .number, minValue: 0, maxValue: 3650),
                    .init(key: "activityHistoryMaxEntries", label: "Max Entries", type: .number, minValue: 0, maxValue: 100000),
                ]
            ),
        ]
    ),
    .init(
        id: "timeouts",
        title: "Timeouts",
        icon: "clock",
        summary: "Docker, Git, and network operation timeouts",
        sections: [
            .init(
                id: "docker-operations",
                title: "Docker Operations",
                fields: [
                    .init(key: "dockerApiTimeout", label: "Docker API (s)", type: .number, minValue: 1, maxValue: 3600),
                    .init(key: "dockerImagePullTimeout", label: "Image Pull (s)", type: .number, minValue: 30, maxValue: 7200),
                    .init(key: "trivyScanTimeout", label: "Trivy Scan (s)", type: .number, minValue: 60, maxValue: 14400),
                ]
            ),
            .init(
                id: "git-operations",
                title: "Git Operations",
                fields: [
                    .init(key: "gitOperationTimeout", label: "Git Operation (s)", type: .number, minValue: 30, maxValue: 3600),
                ]
            ),
            .init(
                id: "network-operations",
                title: "Network Operations",
                fields: [
                    .init(key: "httpClientTimeout", label: "HTTP Client (s)", type: .number, minValue: 5, maxValue: 300),
                    .init(key: "registryTimeout", label: "Registry (s)", type: .number, minValue: 5, maxValue: 300),
                    .init(key: "proxyRequestTimeout", label: "Proxy Request (s)", type: .number, minValue: 10, maxValue: 600),
                ]
            ),
        ]
    ),
]

// MARK: - Environment Settings Hub

private struct EnvironmentSettingsTarget: Identifiable, Hashable {
    let environmentID: EnvironmentID
    let environmentName: String

    var id: String { environmentID.rawValue }
}

struct SystemSettingsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(FleetStore.self) private var fleet

    @State private var selectedTarget: EnvironmentSettingsTarget?

    private var isAdmin: Bool { manager.currentUser?.isAdmin == true }

    private var appSelectedTarget: EnvironmentSettingsTarget {
        EnvironmentSettingsTarget(
            environmentID: manager.activeEnvironmentID,
            environmentName: manager.activeEnvironmentName
        )
    }

    private var settingsTarget: EnvironmentSettingsTarget {
        selectedTarget ?? appSelectedTarget
    }

    private var availableTargets: [EnvironmentSettingsTarget] {
        let loadedTargets = fleet.environments.map {
            EnvironmentSettingsTarget(
                environmentID: EnvironmentID(rawValue: $0.id),
                environmentName: $0.displayName
            )
        }
        guard !loadedTargets.contains(where: { $0.id == settingsTarget.id }) else {
            return loadedTargets
        }
        return [settingsTarget] + loadedTargets
    }

    private var targetIDBinding: Binding<String> {
        Binding(
            get: { settingsTarget.id },
            set: { id in
                guard let target = availableTargets.first(where: { $0.id == id }) else { return }
                selectedTarget = target
            }
        )
    }

    var body: some View {
        let target = settingsTarget

        List {
            Section {
                Picker(selection: targetIDBinding) {
                    ForEach(availableTargets) { environment in
                        Text(environment.environmentName).tag(environment.id)
                    }
                } label: {
                    Label("Settings Environment", systemImage: "server.rack")
                }
                .pickerStyle(.menu)
                .disabled(fleet.isLoading || availableTargets.count < 2)
            } footer: {
                Text("Choose which environment these settings edit. This does not change the environment used elsewhere in the app.")
            }

            Section("Configuration") {
                ForEach(environmentConfigurationCategories) { category in
                    NavigationLink(
                        destination: SettingsCategoryView(
                            category: category,
                            environmentID: target.environmentID,
                            environmentName: target.environmentName
                        )
                    ) {
                        SettingsCategoryRow(category: category)
                    }
                }
            }

            Section("Services") {
                ForEach(environmentServiceCategories) { category in
                    NavigationLink(
                        destination: SettingsCategoryView(
                            category: category,
                            environmentID: target.environmentID,
                            environmentName: target.environmentName
                        )
                    ) {
                        SettingsCategoryRow(category: category)
                    }

                    if category.id == "activity" {
                        NavigationLink(
                            destination: BuildSettingsView(
                                environmentID: target.environmentID,
                                environmentName: target.environmentName
                            )
                        ) {
                            HStack(spacing: 12) {
                                Image(systemName: "hammer")
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Builds")
                                    Text("Build provider, timeout, and Depot credentials")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }

            if isAdmin {
                Section("Maintenance") {
                    NavigationLink(
                        destination: SystemUpgradeView(
                            environmentID: target.environmentID,
                            environmentName: target.environmentName
                        )
                    ) {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Upgrade Arcane")
                                Text("Update to the latest Arcane release")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Environment Settings")
        .task {
            await loadEnvironments()
        }
        .refreshable {
            await loadEnvironments(refresh: true)
        }
    }

    private func loadEnvironments(refresh: Bool = false) async {
        if selectedTarget == nil {
            selectedTarget = appSelectedTarget
        }

        await fleet.load(manager: manager, refresh: refresh)

        guard !Task.isCancelled,
              let selectedTarget,
              let environment = fleet.environments.first(where: { $0.id == selectedTarget.id }) else {
            return
        }
        self.selectedTarget = EnvironmentSettingsTarget(
            environmentID: EnvironmentID(rawValue: environment.id),
            environmentName: environment.displayName
        )
    }
}

// MARK: - Category Row

struct SettingsCategoryRow: View {
    let category: SettingsCategoryDef

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category.icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                Text(category.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Generic Category Detail View

struct SettingsCategoryView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let category: SettingsCategoryDef
    let environmentID: EnvironmentID
    let environmentName: String

    @State private var settings: [String: String] = [:]
    @State private var originalSettings: [String: String] = [:]
    @State private var runningContainers: [ContainerSummary] = []
    @State private var dockerNetworkNames: [String] = []
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var hasChanges: Bool {
        category.fields.contains { settings[$0.key] != originalSettings[$0.key] }
    }

    /// Whether this category has a field that needs the running-container list.
    private var needsContainers: Bool {
        category.fields.contains {
            if case .containerMultiSelect = $0.type { return true }
            return false
        }
    }

    private var needsNetworks: Bool {
        category.fields.contains {
            if case .networkSelect = $0.type { return true }
            return false
        }
    }

    private var trivyNetworkOptions: [String] {
        var options = ["", "bridge", "host", "none"]
        for networkName in dockerNetworkNames where !options.contains(networkName) {
            options.append(networkName)
        }

        let selectedNetwork = settings["trivyNetwork"] ?? ""
        if !selectedNetwork.isEmpty, !options.contains(selectedNetwork) {
            options.append(selectedNetwork)
        }
        return options
    }

    var body: some View {
        Form {
            ForEach(category.sections) { settingsSection in
                Section(settingsSection.title) {
                    ForEach(settingsSection.fields) { field in
                        if isFieldVisible(field) {
                            settingRow(field)
                        }
                    }
                }
            }

            if let error = errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
        .settingsSaveBar(
            hasChanges: hasChanges,
            isSaving: isSaving,
            isInteractionDisabled: isLoading,
            onSave: { Task { await saveSettings() } },
            onRevert: revertChanges
        )
        .task(id: environmentID.rawValue) {
            await reloadSettings()
        }
        .refreshable {
            await reloadSettings()
        }
        .overlay {
            if isLoading && settings.isEmpty {
                ProgressView("Loading…")
            }
        }
    }

    private func revertChanges() {
        for field in category.fields {
            settings[field.key] = originalSettings[field.key] ?? ""
        }
        errorMessage = nil
    }

    private func isFieldVisible(_ field: SettingFieldDef) -> Bool {
        guard let condition = field.visibleWhen else { return true }
        return settings[condition.key] == condition.value
    }

    @ViewBuilder
    private func settingRow(_ field: SettingFieldDef) -> some View {
        let binding = Binding<String>(
            get: { settings[field.key] ?? "" },
            set: { settings[field.key] = $0 }
        )
        let boolBinding = Binding<Bool>(
            get: { settings[field.key]?.lowercased() == "true" },
            set: { settings[field.key] = String($0) }
        )
        let layout: FormFieldLayout = field.stacked ? .stacked : .automatic

        switch field.type {
        case .boolean:
            Toggle(field.label, isOn: boolBinding)
        case .number:
            FormNumberField(
                title: field.label,
                placeholder: "0",
                text: binding,
                minValue: field.minValue,
                maxValue: field.maxValue,
                helper: rangeHint(field)
            )
        case .password:
            FormSecureField(title: field.label, placeholder: "Secret value", text: binding, helper: field.description)
        case .select(let options):
            let pickerBinding = Binding<String>(
                get: {
                    let current = settings[field.key] ?? ""
                    return options.contains(current) ? current : (options.first ?? "")
                },
                set: { settings[field.key] = $0 }
            )
            FormPicker(title: field.label, selection: pickerBinding, helper: field.description) {
                ForEach(options, id: \.self) { option in
                    // Show a friendly label ("Older Than") but keep the raw API
                    // value ("olderThan") as the tag so the saved value is unchanged.
                    Text(optionLabel(option)).tag(option)
                }
            }
        case .networkSelect:
            FormPicker(title: field.label, selection: binding, helper: field.description) {
                ForEach(trivyNetworkOptions, id: \.self) { option in
                    Text(option.isEmpty ? "Auto" : option).tag(option)
                }
            }
        case .cron:
            FormTextField(
                title: field.label,
                placeholder: "* * * * *",
                text: binding,
                autocapitalization: .never,
                autocorrectionDisabled: true,
                monospaced: true,
                helper: field.description,
                layout: layout
            )
        case .text:
            FormTextField(
                title: field.label,
                placeholder: "Value",
                text: binding,
                autocapitalization: .never,
                autocorrectionDisabled: true,
                helper: field.description,
                layout: layout
            )
        case .textarea:
            FormTextField(
                title: field.label,
                placeholder: "Value",
                text: binding,
                autocapitalization: .never,
                autocorrectionDisabled: true,
                axis: .vertical,
                lineLimit: 3...10,
                monospaced: true,
                helper: field.description,
                layout: layout
            )
        case .containerMultiSelect:
            NavigationLink {
                ContainerMultiSelectView(
                    title: field.label,
                    selection: binding,
                    containers: runningContainers
                )
            } label: {
                LabeledContent(field.label) {
                    Text(excludedCountLabel(binding.wrappedValue))
                }
            }
        }
    }

    /// Summary shown on the picker's row: "None" or the number of excluded names.
    private func excludedCountLabel(_ raw: String) -> String {
        let count = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .count
        return count == 0 ? "None" : "\(count)"
    }

    // MARK: - API

    private func reloadSettings() async {
        isLoading = true
        errorMessage = nil
        settings = [:]
        originalSettings = [:]
        runningContainers = []
        dockerNetworkNames = []
        defer { isLoading = false }

        await loadSettings(for: environmentID)
        guard !Task.isCancelled else { return }
        if needsContainers {
            await loadContainers(for: environmentID)
        }
        if needsNetworks {
            await loadNetworks(for: environmentID)
        }
    }

    private func loadSettings(for environmentID: EnvironmentID) async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "settings")
            let rawData = try await client.transport.rawRequest(path, body: Optional<String>.none)
            let dtos = try JSONDecoder().decode([PublicSetting].self, from: rawData)
            var dict: [String: String] = [:]
            for dto in dtos {
                dict[dto.key] = dto.value
            }
            guard !Task.isCancelled else { return }
            settings = dict
            originalSettings = dict
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = friendlyErrorMessage(error)
        }
    }

    /// Loads the current running containers to populate the exclusion picker.
    /// Non-fatal on failure — the picker still shows already-excluded names.
    private func loadContainers(for environmentID: EnvironmentID) async {
        guard let client = manager.client else { return }
        do {
            let list = try await PaginationLoader.collect { start, limit in
                let response = try await client.containers.list(
                    envID: environmentID,
                    query: .init(start: start, limit: limit)
                )
                return ResourcePage(items: response.data, pagination: response.pagination)
            }
            guard !Task.isCancelled else { return }
            runningContainers = list
                .filter { $0.isRunning }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        } catch {
            // Ignore — leave the picker to show preserved names / manual state.
        }
    }

    /// Loads the selected environment's Docker networks for the Trivy menu.
    /// Failure is non-fatal because Auto and Docker's built-in modes remain valid.
    private func loadNetworks(for environmentID: EnvironmentID) async {
        guard let client = manager.client else { return }
        do {
            let networks = try await PaginationLoader.collect(pageSize: 1_000) { start, limit in
                let response = try await client.networks.list(
                    envID: environmentID,
                    query: .init(start: start, limit: limit)
                )
                return ResourcePage(items: response.data, pagination: response.pagination)
            }
            guard !Task.isCancelled else { return }
            let builtInNames: Set<String> = ["bridge", "host", "none"]
            dockerNetworkNames = Array(
                Set(
                    networks
                        .map(\.name)
                        .filter { !$0.isEmpty && !builtInNames.contains($0) }
                )
            )
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        } catch {
            guard !Task.isCancelled else { return }
            showToast(.info("Couldn’t load Docker networks. Showing built-in options only."))
        }
    }

    private func saveSettings() async {
        guard let client = manager.client else { return }

        if let validationError = validate() {
            errorMessage = validationError
            return
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        var changedPairs: [String: String] = [:]
        for field in category.fields {
            let value = settings[field.key] ?? ""
            if value != originalSettings[field.key] {
                changedPairs[field.key] = value
            }
        }
        guard !changedPairs.isEmpty else { return }

        do {
            // Settings are flat string key/values server-side; send the raw dict so we
            // aren't limited to keys the SDK's UpdateSettings struct happens to model.
            let path = client.rest.environmentPath(environmentID, "settings")
            let _: [PublicSetting] = try await client.rest.put(path, body: changedPairs)
            guard !Task.isCancelled else { return }
            for (key, value) in changedPairs {
                originalSettings[key] = value
            }
            showToast(.success("Settings saved for \(environmentName)"))
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = friendlyErrorMessage(error)
        }
    }

    /// Validates numeric fields against their allowed range before saving.
    private func validate() -> String? {
        for field in category.fields {
            guard case .number = field.type else { continue }
            let raw = (settings[field.key] ?? "").trimmingCharacters(in: .whitespaces)
            if raw.isEmpty { continue }
            guard let num = Int(raw) else {
                return "\(field.label) must be a whole number."
            }
            if let min = field.minValue, num < min {
                return "\(field.label) must be at least \(min)."
            }
            if let max = field.maxValue, num > max {
                return "\(field.label) must be at most \(max)."
            }
        }
        return nil
    }

    /// Turns a raw select option value into a friendly, human-readable label
    /// (e.g. "olderThan" → "Older Than", "dangling" → "Dangling"). Splits
    /// camelCase into words and capitalizes each; the raw value stays the tag.
    private func optionLabel(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        var spaced = ""
        for character in raw {
            if character.isUppercase, !spaced.isEmpty {
                spaced.append(" ")
            }
            spaced.append(character)
        }
        return spaced
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// A short "Allowed: min–max" hint shown under numeric fields that declare a range.
    private func rangeHint(_ field: SettingFieldDef) -> String? {
        switch (field.minValue, field.maxValue) {
        case let (min?, max?): return "Allowed: \(min)–\(max)"
        case let (min?, nil): return "Minimum: \(min)"
        case let (nil, max?): return "Maximum: \(max)"
        default: return nil
        }
    }
}

// MARK: - Excluded Containers Picker

/// Multi-select checklist of running containers that builds the comma-separated
/// exclusion string used by auto-update / auto-heal. Matches the web frontend's
/// format: names are normalized by stripping any leading "/", joined with commas.
///
/// Already-excluded names that aren't currently running are still listed (marked
/// "Not running") so they can be unchecked instead of silently persisting.
struct ContainerMultiSelectView: View {
    let title: String
    @Binding var selection: String
    let containers: [ContainerSummary]

    @State private var search = ""

    private func normalize(_ name: String) -> String {
        var value = name
        while value.hasPrefix("/") { value.removeFirst() }
        return value
    }

    private var selectedNames: Set<String> {
        Set(
            selection
                .split(separator: ",")
                .map { normalize($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
        )
    }

    private struct Row: Identifiable {
        let name: String
        let isRunning: Bool
        var id: String { name }
    }

    private var allRows: [Row] {
        let running = containers.map { Row(name: $0.displayName, isRunning: true) }
        let runningNames = Set(running.map(\.name))
        let orphaned = selectedNames
            .subtracting(runningNames)
            .sorted()
            .map { Row(name: $0, isRunning: false) }
        return running + orphaned
    }

    private var filteredRows: [Row] {
        guard !search.isEmpty else { return allRows }
        return allRows.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            if allRows.isEmpty {
                ContentUnavailableView(
                    "No Containers",
                    systemImage: "shippingbox",
                    description: Text("Running containers will appear here to exclude from this job.")
                )
            } else {
                Section {
                    ForEach(filteredRows) { row in
                        Button {
                            toggle(row.name)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.name)
                                        .foregroundStyle(.primary)
                                    if !row.isRunning {
                                        Text("Not running")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 12)
                                if selectedNames.contains(row.name) {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Selected containers are skipped by this job. Names are matched exactly.")
                }
            }
        }
        .searchable(text: $search, prompt: "Search containers")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggle(_ name: String) {
        let normalized = normalize(name)
        var set = selectedNames
        if set.contains(normalized) {
            set.remove(normalized)
        } else {
            set.insert(normalized)
        }
        selection = set.sorted().joined(separator: ",")
    }
}
