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
    var id: String { key }
}

enum SettingFieldType {
    case text
    case number
    case boolean
    case password
    case select([String])
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
    let fields: [SettingFieldDef]
}

let systemSettingsCategories: [SettingsCategoryDef] = [
    .init(
        id: "general",
        title: "General",
        icon: "gear",
        summary: "Server URL, gravatar, default shell",
        fields: [
            .init(key: "baseServerUrl", label: "Base Server URL", type: .text, stacked: true),
            .init(key: "diskUsagePath", label: "Disk Usage Path", type: .text, stacked: true),
            .init(key: "enableGravatar", label: "Enable Gravatar", type: .boolean),
            .init(key: "defaultShell", label: "Default Shell", type: .text),
            .init(key: "autoInjectEnv", label: "Auto-Inject .env", type: .boolean),
            .init(key: "defaultDeployPullPolicy", label: "Default Pull Policy", type: .select(["missing", "always", "never"])),
        ]
    ),
    .init(
        id: "docker",
        title: "Directories",
        icon: "folder",
        summary: "Project, template, and swarm directories",
        fields: [
            .init(key: "projectsDirectory", label: "Projects Directory", type: .text, stacked: true),
            .init(key: "templatesDirectory", label: "Templates Directory", type: .text, stacked: true),
            .init(key: "swarmStackSourcesDirectory", label: "Swarm Stack Sources", type: .text, stacked: true),
            .init(key: "followProjectSymlinks", label: "Follow Project Symlinks", type: .boolean),
        ]
    ),
    .init(
        id: "auto-update",
        title: "Auto-Update",
        icon: "arrow.triangle.2.circlepath",
        summary: "Automatic image updates and polling",
        fields: [
            .init(key: "autoUpdate", label: "Enabled", type: .boolean),
            .init(key: "autoUpdateInterval", label: "Update Interval", type: .cron),
            .init(key: "autoUpdateExcludedContainers", label: "Excluded Containers", type: .containerMultiSelect),
            .init(key: "pollingEnabled", label: "Polling Enabled", type: .boolean),
            .init(key: "pollingInterval", label: "Polling Interval", type: .cron),
        ]
    ),
    .init(
        id: "auto-heal",
        title: "Auto-Heal",
        icon: "heart.text.square",
        summary: "Restart unhealthy containers automatically",
        fields: [
            .init(key: "autoHealEnabled", label: "Enabled", type: .boolean),
            .init(key: "autoHealInterval", label: "Check Interval", type: .cron),
            .init(key: "autoHealMaxRestarts", label: "Max Restarts", type: .number),
            .init(key: "autoHealRestartWindow", label: "Restart Window (min)", type: .number),
            .init(key: "autoHealExcludedContainers", label: "Excluded Containers", type: .containerMultiSelect),
        ]
    ),
    .init(
        id: "prune",
        title: "Scheduled Pruning",
        icon: "trash.circle",
        summary: "Automatically clean up unused resources",
        fields: [
            .init(key: "scheduledPruneEnabled", label: "Enabled", type: .boolean),
            .init(key: "scheduledPruneInterval", label: "Interval", type: .cron),
            .init(key: "pruneContainerMode", label: "Prune Containers", type: .select(["none", "stopped", "olderThan"])),
            .init(key: "pruneContainerUntil", label: "Container Age Filter", type: .text),
            .init(key: "pruneImageMode", label: "Prune Images", type: .select(["none", "dangling", "all", "olderThan"])),
            .init(key: "pruneImageUntil", label: "Image Age Filter", type: .text),
            .init(key: "pruneVolumeMode", label: "Prune Volumes", type: .select(["none", "anonymous", "all"])),
            .init(key: "pruneNetworkMode", label: "Prune Networks", type: .select(["none", "unused", "olderThan"])),
            .init(key: "pruneNetworkUntil", label: "Network Age Filter", type: .text),
            .init(key: "pruneBuildCacheMode", label: "Prune Build Cache", type: .select(["none", "unused", "all", "olderThan"])),
            .init(key: "pruneBuildCacheUntil", label: "Build Cache Age Filter", type: .text),
        ]
    ),
    .init(
        id: "maintenance",
        title: "Maintenance Schedule",
        icon: "calendar.badge.clock",
        summary: "Background job and cleanup intervals",
        fields: [
            .init(key: "environmentHealthInterval", label: "Environment Health Check", type: .cron),
            .init(key: "dockerClientRefreshInterval", label: "Docker Client Refresh", type: .cron),
            .init(key: "eventCleanupInterval", label: "Event Cleanup", type: .cron),
            .init(key: "expiredSessionsCleanupInterval", label: "Expired Sessions Cleanup", type: .cron),
        ]
    ),
    .init(
        id: "vulnerability",
        title: "Vulnerability Scanning",
        icon: "shield.lefthalf.filled",
        summary: "Trivy scanner configuration",
        fields: [
            .init(key: "vulnerabilityScanEnabled", label: "Enabled", type: .boolean),
            .init(key: "vulnerabilityScanInterval", label: "Scan Interval", type: .cron),
            .init(key: "trivyImage", label: "Trivy Image", type: .text, stacked: true),
            .init(key: "trivyNetwork", label: "Network", type: .text),
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
    .init(
        id: "activity",
        title: "Activity",
        icon: "list.bullet.rectangle",
        summary: "Activity Center history retention",
        fields: [
            .init(key: "activityHistoryRetentionDays", label: "Retention (days)", type: .number, minValue: 0, maxValue: 3650),
            .init(key: "activityHistoryMaxEntries", label: "Max Entries", type: .number, minValue: 0, maxValue: 100000),
        ]
    ),
    .init(
        id: "timeouts",
        title: "Timeouts",
        icon: "clock",
        summary: "Operation timeouts in seconds",
        fields: [
            .init(key: "dockerApiTimeout", label: "Docker API (s)", type: .number, minValue: 1, maxValue: 3600),
            .init(key: "dockerImagePullTimeout", label: "Image Pull (s)", type: .number, minValue: 30, maxValue: 7200),
            .init(key: "trivyScanTimeout", label: "Trivy Scan (s)", type: .number, minValue: 60, maxValue: 14400),
            .init(key: "gitOperationTimeout", label: "Git Operation (s)", type: .number, minValue: 30, maxValue: 3600),
            .init(key: "httpClientTimeout", label: "HTTP Client (s)", type: .number, minValue: 5, maxValue: 300),
            .init(key: "registryTimeout", label: "Registry (s)", type: .number, minValue: 5, maxValue: 300),
            .init(key: "proxyRequestTimeout", label: "Proxy Request (s)", type: .number, minValue: 10, maxValue: 600),
        ]
    ),
    .init(
        id: "git-sync",
        title: "Git Sync Limits",
        icon: "arrow.triangle.branch",
        summary: "Repository sync size and file limits",
        fields: [
            .init(key: "gitSyncMaxFiles", label: "Max Files", type: .number),
            .init(key: "gitSyncMaxTotalSizeMb", label: "Max Total Size (MB)", type: .number),
            .init(key: "gitSyncMaxBinarySizeMb", label: "Max Binary Size (MB)", type: .number),
        ]
    ),
    .init(
        id: "misc",
        title: "Miscellaneous",
        icon: "ellipsis.circle",
        summary: "Additional settings",
        fields: [
            .init(key: "maxImageUploadSize", label: "Max Image Upload (MB)", type: .number),
        ]
    ),
]

// MARK: - System Settings Hub

struct SystemSettingsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager

    private var isAdmin: Bool { manager.currentUser?.isAdmin == true }

    var body: some View {
        List {
            Section {
                ForEach(systemSettingsCategories) { category in
                    NavigationLink(destination: SettingsCategoryView(category: category)) {
                        SettingsCategoryRow(category: category)
                    }
                }
                NavigationLink(destination: BuildSettingsView()) {
                    HStack(spacing: 12) {
                        Image(systemName: "hammer")
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Builds")
                            Text("Build provider, timeout, and Depot credentials")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } footer: {
                Text("Settings apply to the active environment: \(manager.activeEnvironmentName)")
            }

            if isAdmin {
                Section("Maintenance") {
                    NavigationLink(destination: SystemUpgradeView(environmentID: manager.activeEnvironmentID)) {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Upgrade Arcane")
                                Text("Update to the latest Arcane release")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("System Settings")
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
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Generic Category Detail View

struct SettingsCategoryView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let category: SettingsCategoryDef

    @State private var settings: [String: String] = [:]
    @State private var originalSettings: [String: String] = [:]
    @State private var runningContainers: [ContainerSummary] = []
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

    var body: some View {
        Form {
            Section {
                ForEach(category.fields) { field in
                    settingRow(field)
                }
            }

            if hasChanges {
                Section {
                    Button {
                        Task { await saveSettings() }
                    } label: {
                        HStack {
                            Spacer()
                            if isSaving {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Label("Save Changes", systemImage: "checkmark.circle")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isSaving)

                    Button(role: .destructive) {
                        for field in category.fields {
                            settings[field.key] = originalSettings[field.key] ?? ""
                        }
                    } label: {
                        HStack {
                            Spacer()
                            Text("Discard Changes")
                            Spacer()
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
        .task {
            await loadSettings()
            if needsContainers { await loadContainers() }
        }
        .refreshable {
            await loadSettings()
            if needsContainers { await loadContainers() }
        }
        .overlay {
            if isLoading && settings.isEmpty {
                ProgressView("Loading…")
            }
        }
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

    private func loadSettings() async {
        guard let client = manager.client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let path = client.rest.environmentPath(manager.activeEnvironmentID, "settings")
            let rawData = try await client.transport.rawRequest(path, body: Optional<String>.none)
            let dtos = try JSONDecoder().decode([PublicSetting].self, from: rawData)
            var dict: [String: String] = [:]
            for dto in dtos {
                dict[dto.key] = dto.value
            }
            settings = dict
            originalSettings = dict
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    /// Loads the current running containers to populate the exclusion picker.
    /// Non-fatal on failure — the picker still shows already-excluded names.
    private func loadContainers() async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(manager.activeEnvironmentID, "containers")
            let list: [ContainerSummary] = try await client.rest.get(path)
            runningContainers = list
                .filter { $0.isRunning }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        } catch {
            // Ignore — leave the picker to show preserved names / manual state.
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
            let path = client.rest.environmentPath(manager.activeEnvironmentID, "settings")
            let _: [PublicSetting] = try await client.rest.put(path, body: changedPairs)
            for (key, value) in changedPairs {
                originalSettings[key] = value
            }
            showToast(.success("Settings saved"))
        } catch {
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
        Group {
            if allRows.isEmpty {
                ContentUnavailableView(
                    "No Containers",
                    systemImage: "shippingbox",
                    description: Text("Running containers will appear here to exclude from this job.")
                )
            } else {
                List {
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
                .searchable(text: $search, prompt: "Search containers")
            }
        }
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
