import Arcane
import SwiftUI

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

// MARK: - Environment settings tabs

/// Settings shown on an environment's detail page, grouped like the web's
/// environment tabs. Each tab's sections save through one shared draft.
let environmentFeatureSections: [SettingsSectionDef] = [
    .init(
        id: "features",
        title: "Features",
        fields: [
            .init(
                key: "featureVulnerabilityManagementEnabled", label: "Vulnerability Management", type: .boolean,
                description: "Image scanning, vulnerability reports, and patching."),
            .init(
                key: "featureSwarmEnabled", label: "Swarm", type: .boolean,
                description: "Swarm services, stacks, nodes, and secrets."),
        ]
    )
]

let environmentStorageSections: [SettingsSectionDef] = [
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
        id: "upload-limits",
        title: "Upload Limits",
        fields: [
            .init(key: "maxImageUploadSize", label: "Max Image Upload (MB)", type: .number)
        ]
    ),
    .init(
        id: "git-sync-limits",
        title: "Git Sync File Limits",
        fields: [
            .init(key: "gitSyncMaxFiles", label: "Max Files", type: .number),
            .init(key: "gitSyncMaxTotalSizeMb", label: "Total Size (MB)", type: .number),
            .init(key: "gitSyncMaxBinarySizeMb", label: "Binary File Size (MB)", type: .number),
        ]
    ),
]

let environmentDockerSections: [SettingsSectionDef] = [
    .init(
        id: "docker",
        title: "Docker Settings",
        fields: [
            .init(key: "baseServerUrl", label: "Base Server URL", type: .text, stacked: true),
            .init(
                key: "defaultShell", label: "Default Shell",
                type: .select(["/bin/sh", "/bin/bash", "/bin/ash", "/bin/zsh"])),
            .init(
                key: "defaultDeployPullPolicy", label: "Default Pull Policy",
                type: .select(["missing", "always", "never"])),
            .init(key: "autoInjectEnv", label: "Auto-Inject .env", type: .boolean),
            .init(key: "toolsImageRegistry", label: "Tools Image Registry", type: .text, stacked: true),
            .init(key: "updateCheckRegistry", label: "Update Check Registry", type: .text, stacked: true),
        ]
    ),
    .init(
        id: "prune-options",
        title: "Prune Options",
        fields: [
            .init(
                key: "pruneContainerMode", label: "Prune Containers",
                type: .select(["none", "stopped", "olderThan"])),
            .init(
                key: "pruneContainerUntil", label: "Container Age Filter", type: .text,
                visibleWhen: .init(key: "pruneContainerMode", value: "olderThan")),
            .init(
                key: "pruneImageMode", label: "Prune Images",
                type: .select(["none", "dangling", "all", "olderThan"])),
            .init(
                key: "pruneImageUntil", label: "Image Age Filter", type: .text,
                visibleWhen: .init(key: "pruneImageMode", value: "olderThan")),
            .init(key: "pruneVolumeMode", label: "Prune Volumes", type: .select(["none", "anonymous", "all"])),
            .init(
                key: "pruneNetworkMode", label: "Prune Networks",
                type: .select(["none", "unused", "olderThan"])),
            .init(
                key: "pruneNetworkUntil", label: "Network Age Filter", type: .text,
                visibleWhen: .init(key: "pruneNetworkMode", value: "olderThan")),
            .init(
                key: "pruneBuildCacheMode", label: "Prune Build Cache",
                type: .select(["none", "unused", "all", "olderThan"])),
            .init(
                key: "pruneBuildCacheUntil", label: "Build Cache Age Filter", type: .text,
                visibleWhen: .init(key: "pruneBuildCacheMode", value: "olderThan")),
        ]
    ),
]

/// The web's Security tab sub-tabs.
enum EnvironmentSecuritySection: String, CaseIterable, Identifiable {
    case scanning = "Scanning"
    case patching = "Patching"
    case lifecycle = "Lifecycle"

    var id: String { rawValue }

    var sections: [SettingsSectionDef] {
        switch self {
        case .scanning:
            [
                .init(
                    id: "vulnerability-scanning",
                    title: "Vulnerability Scanning",
                    fields: [
                        .init(key: "trivyDbRegistry", label: "Database Registry", type: .text, stacked: true),
                        .init(
                            key: "trivyNetwork", label: "Network", type: .networkSelect,
                            description:
                                "Auto inherits Arcane's network. Choose a built-in or custom Docker network to override it."
                        ),
                        .init(
                            key: "trivyConcurrentScanContainers", label: "Concurrent Scans", type: .number, minValue: 1),
                        .init(key: "trivyIgnoreUnfixed", label: "Ignore Unfixed", type: .boolean),
                        .init(key: "vulnerabilityThreatIntelEnabled", label: "Threat Intelligence", type: .boolean),
                        .init(key: "trivyPrivileged", label: "Privileged Mode", type: .boolean),
                        .init(key: "trivySecurityOpts", label: "Security Options", type: .textarea),
                    ]
                ),
                .init(
                    id: "scanner-resources",
                    title: "Resource Limits",
                    fields: [
                        .init(key: "trivyResourceLimitsEnabled", label: "Limit Resources", type: .boolean),
                        .init(
                            key: "trivyCpuLimit", label: "CPU Limit", type: .text,
                            visibleWhen: .init(key: "trivyResourceLimitsEnabled", value: "true")),
                        .init(
                            key: "trivyMemoryLimitMb", label: "Memory Limit (MB)", type: .number,
                            visibleWhen: .init(key: "trivyResourceLimitsEnabled", value: "true")),
                    ]
                ),
                .init(
                    id: "trivy-server",
                    title: "Trivy Server",
                    fields: [
                        .init(key: "trivyServerEnabled", label: "Use Trivy Server", type: .boolean),
                        .init(
                            key: "trivyServerUrl", label: "Server URL", type: .text, stacked: true,
                            visibleWhen: .init(key: "trivyServerEnabled", value: "true")),
                        .init(
                            key: "trivyServerToken", label: "Token", type: .password,
                            visibleWhen: .init(key: "trivyServerEnabled", value: "true")),
                    ]
                ),
                .init(
                    id: "trivy-config",
                    title: "Configuration",
                    fields: [
                        .init(key: "trivyConfig", label: "Trivy Config (YAML)", type: .textarea),
                        .init(key: "trivyIgnore", label: ".trivyignore", type: .textarea),
                    ]
                ),
            ]
        case .patching:
            [
                .init(
                    id: "image-patching",
                    title: "Image Patching",
                    fields: [
                        .init(key: "imageAutoPatchEnabled", label: "Auto-Patch Images", type: .boolean),
                        .init(key: "imagePatchAllPlatforms", label: "Patch All Platforms", type: .boolean),
                        .init(key: "imagePatchSuffix", label: "Tag Suffix", type: .text),
                        .init(key: "imagePatchTimeoutSec", label: "Timeout (s)", type: .number, minValue: 1),
                    ]
                )
            ]
        case .lifecycle:
            [
                .init(
                    id: "lifecycle-hooks",
                    title: "Lifecycle Hooks",
                    fields: [
                        .init(key: "lifecycleEnabled", label: "Lifecycle Hooks", type: .boolean),
                        .init(
                            key: "lifecycleDefaultRunnerImage", label: "Default Runner Image", type: .text,
                            stacked: true),
                        .init(key: "lifecycleMaxTimeoutSec", label: "Max Timeout (s)", type: .number, minValue: 1),
                    ]
                )
            ]
        }
    }
}

let environmentAutomationSections: [SettingsSectionDef] = [
    .init(
        id: "updates",
        title: "Updates",
        fields: [
            .init(key: "pollingEnabled", label: "Image Polling", type: .boolean),
            .init(key: "imageEventWatcherEnabled", label: "Image Event Watcher", type: .boolean),
            .init(key: "autoUpdate", label: "Auto-Update", type: .boolean),
            .init(key: "autoUpdateExcludedContainers", label: "Excluded Containers", type: .containerMultiSelect),
        ]
    ),
    .init(
        id: "monitoring",
        title: "Monitoring",
        fields: [
            .init(key: "autoHealEnabled", label: "Auto-Heal", type: .boolean),
            .init(key: "autoHealExcludedContainers", label: "Excluded Containers", type: .containerMultiSelect),
            .init(key: "autoHealMaxRestarts", label: "Max Restarts", type: .number),
            .init(key: "autoHealRestartWindow", label: "Restart Window (min)", type: .number),
        ]
    ),
    .init(
        id: "maintenance",
        title: "Maintenance",
        fields: [
            .init(key: "scheduledPruneEnabled", label: "Scheduled Pruning", type: .boolean),
            .init(key: "vulnerabilityScanEnabled", label: "Scheduled Vulnerability Scans", type: .boolean),
        ]
    ),
]

// MARK: - Server-wide settings

/// Settings that apply to the whole Arcane server, stored on the local
/// environment like the web's Settings pages.
let activityHistorySettings = SettingsCategoryDef(
    id: "activity",
    title: "Activity History",
    icon: "list.bullet.rectangle",
    summary: "Activity Center history retention",
    sections: [
        .init(
            id: "activity-history",
            title: "Activity History",
            fields: [
                .init(
                    key: "activityHistoryRetentionDays", label: "Retention (days)", type: .number, minValue: 0,
                    maxValue: 3650),
                .init(
                    key: "activityHistoryMaxEntries", label: "Max Entries", type: .number, minValue: 0,
                    maxValue: 100000),
            ]
        )
    ]
)

let timeoutSettings = SettingsCategoryDef(
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
                .init(
                    key: "dockerImagePullTimeout", label: "Image Pull (s)", type: .number, minValue: 30,
                    maxValue: 7200),
                .init(key: "trivyScanTimeout", label: "Trivy Scan (s)", type: .number, minValue: 60, maxValue: 14400),
            ]
        ),
        .init(
            id: "git-operations",
            title: "Git Operations",
            fields: [
                .init(
                    key: "gitOperationTimeout", label: "Git Operation (s)", type: .number, minValue: 30, maxValue: 3600)
            ]
        ),
        .init(
            id: "network-operations",
            title: "Network Operations",
            fields: [
                .init(key: "httpClientTimeout", label: "HTTP Client (s)", type: .number, minValue: 5, maxValue: 300),
                .init(key: "registryTimeout", label: "Registry (s)", type: .number, minValue: 5, maxValue: 300),
                .init(
                    key: "proxyRequestTimeout", label: "Proxy Request (s)", type: .number, minValue: 10, maxValue: 600),
            ]
        ),
    ]
)

// MARK: - Draft

/// One environment's settings while they're being edited: loads the flat
/// key/value settings, tracks edits, and saves only what changed.
@MainActor @Observable
final class EnvironmentSettingsDraft {
    let environmentID: EnvironmentID
    let environmentName: String

    var values: [String: String] = [:]
    private(set) var original: [String: String] = [:]
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var isSaving = false
    var errorMessage: String?
    private(set) var runningContainers: [ContainerSummary] = []
    private(set) var networkNames: [String] = []

    init(environmentID: EnvironmentID, environmentName: String) {
        self.environmentID = environmentID
        self.environmentName = environmentName
    }

    var hasChanges: Bool { changedValues.isEmpty == false }

    private var changedValues: [String: String] {
        values.filter { original[$0.key] != $0.value }
    }

    func binding(_ key: String) -> Binding<String> {
        Binding(get: { self.values[key] ?? "" }, set: { self.values[key] = $0 })
    }

    func isVisible(_ field: SettingFieldDef) -> Bool {
        guard let condition = field.visibleWhen else { return true }
        return values[condition.key] == condition.value
    }

    func load(client: ArcaneClient, fields: [SettingFieldDef]) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let path = client.rest.environmentPath(environmentID, "settings")
            let rawData = try await client.transport.rawRequest(path, body: Optional<String>.none)
            let settings = try JSONDecoder().decode([PublicSetting].self, from: rawData)
            guard !Task.isCancelled else { return }
            let loaded = Dictionary(settings.map { ($0.key, $0.value) }, uniquingKeysWith: { _, new in new })
            values = loaded
            original = loaded
            hasLoaded = true
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = friendlyErrorMessage(error)
            return
        }
        if fields.contains(where: { if case .containerMultiSelect = $0.type { true } else { false } }) {
            await loadContainers(client: client)
        }
        if fields.contains(where: { if case .networkSelect = $0.type { true } else { false } }) {
            await loadNetworks(client: client)
        }
    }

    func revert() {
        values = original
        errorMessage = nil
    }

    /// Saves every changed key. Settings are flat string pairs server-side, so
    /// the raw dictionary is sent rather than a typed subset.
    @discardableResult
    func save(client: ArcaneClient, fields: [SettingFieldDef]) async -> Bool {
        if let validationError = validate(fields) {
            errorMessage = validationError
            return false
        }
        let changes = changedValues
        guard !changes.isEmpty else { return true }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let path = client.rest.environmentPath(environmentID, "settings")
            let _: [PublicSetting] = try await client.rest.put(path, body: changes)
            for (key, value) in changes { original[key] = value }
            return true
        } catch {
            errorMessage = friendlyErrorMessage(error)
            return false
        }
    }

    /// Validates numeric fields against their allowed range before saving.
    private func validate(_ fields: [SettingFieldDef]) -> String? {
        for field in fields {
            guard case .number = field.type else { continue }
            let raw = (values[field.key] ?? "").trimmingCharacters(in: .whitespaces)
            if raw.isEmpty { continue }
            guard let number = Int(raw) else { return "\(field.label) must be a whole number." }
            if let min = field.minValue, number < min { return "\(field.label) must be at least \(min)." }
            if let max = field.maxValue, number > max { return "\(field.label) must be at most \(max)." }
        }
        return nil
    }

    /// Running containers for the exclusion pickers. Non-fatal on failure —
    /// the picker still shows already-excluded names.
    private func loadContainers(client: ArcaneClient) async {
        let environmentID = environmentID
        do {
            let list = try await PaginationLoader.collect { start, limit in
                let response = try await client.containers.list(
                    envID: environmentID, query: .init(start: start, limit: limit))
                return ResourcePage(items: response.data, pagination: response.pagination)
            }
            runningContainers =
                list
                .filter { $0.isRunning }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        } catch {
            // Leave the picker showing already-excluded names.
        }
    }

    /// Docker networks for the Trivy network menu. Auto and the built-in modes
    /// stay valid if this fails.
    private func loadNetworks(client: ArcaneClient) async {
        let environmentID = environmentID
        do {
            let networks = try await PaginationLoader.collect(pageSize: 1_000) { start, limit in
                let response = try await client.networks.list(
                    envID: environmentID, query: .init(start: start, limit: limit))
                return ResourcePage(items: response.data, pagination: response.pagination)
            }
            let builtIn: Set<String> = ["bridge", "host", "none"]
            networkNames = Set(networks.map(\.name).filter { !$0.isEmpty && !builtIn.contains($0) })
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        } catch {
            showToast(.info("Couldn’t load Docker networks. Showing built-in options only."))
        }
    }
}

// MARK: - Field row

/// One editable setting, rendered with the app's shared form rows.
struct SettingFieldRow: View {
    let field: SettingFieldDef
    @Bindable var draft: EnvironmentSettingsDraft

    var body: some View {
        let binding = draft.binding(field.key)
        let layout: FormFieldLayout = field.stacked ? .stacked : .automatic

        switch field.type {
        case .boolean:
            Toggle(
                isOn: Binding(
                    get: { binding.wrappedValue.lowercased() == "true" },
                    set: { binding.wrappedValue = String($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.label)
                    if let description = field.description {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .number:
            FormNumberField(
                title: field.label,
                placeholder: "0",
                text: binding,
                minValue: field.minValue,
                maxValue: field.maxValue,
                helper: rangeHint
            )
        case .password:
            FormSecureField(title: field.label, placeholder: "Secret value", text: binding, helper: field.description)
        case .select(let options):
            let selection = Binding<String>(
                get: { options.contains(binding.wrappedValue) ? binding.wrappedValue : (options.first ?? "") },
                set: { binding.wrappedValue = $0 }
            )
            FormPicker(title: field.label, selection: selection, helper: field.description) {
                // Friendly label ("Older Than"), raw API value ("olderThan") as the tag.
                ForEach(options, id: \.self) { option in
                    Text(Self.optionLabel(option)).tag(option)
                }
            }
        case .networkSelect:
            FormPicker(title: field.label, selection: binding, helper: field.description) {
                ForEach(networkOptions(selected: binding.wrappedValue), id: \.self) { option in
                    Text(option.isEmpty ? "Auto" : option).tag(option)
                }
            }
        case .cron, .text, .textarea:
            let isMultiline: Bool = if case .textarea = field.type { true } else { false }
            let isCode: Bool = if case .text = field.type { false } else { true }
            FormTextField(
                title: field.label,
                placeholder: isCode && !isMultiline ? "* * * * *" : "Value",
                text: binding,
                autocapitalization: .never,
                autocorrectionDisabled: true,
                axis: isMultiline ? .vertical : .horizontal,
                lineLimit: isMultiline ? 3...10 : nil,
                monospaced: isCode,
                helper: field.description,
                layout: layout
            )
        case .containerMultiSelect:
            NavigationLink {
                ContainerMultiSelectView(title: field.label, selection: binding, containers: draft.runningContainers)
            } label: {
                LabeledContent(field.label) {
                    Text(excludedCountLabel(binding.wrappedValue))
                }
            }
        }
    }

    private var rangeHint: String? {
        switch (field.minValue, field.maxValue) {
        case (let min?, let max?): "Allowed: \(min)–\(max)"
        case (let min?, nil): "Minimum: \(min)"
        case (nil, let max?): "Maximum: \(max)"
        default: nil
        }
    }

    private func networkOptions(selected: String) -> [String] {
        var options = ["", "bridge", "host", "none"]
        options.append(contentsOf: draft.networkNames.filter { !options.contains($0) })
        if !selected.isEmpty, !options.contains(selected) { options.append(selected) }
        return options
    }

    /// "None" or the number of excluded container names.
    private func excludedCountLabel(_ raw: String) -> String {
        let count = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .count
        return count == 0 ? "None" : String(count)
    }

    /// "olderThan" → "Older Than", "dangling" → "Dangling".
    static func optionLabel(_ raw: String) -> String {
        guard !raw.isEmpty, !raw.hasPrefix("/") else { return raw }
        var spaced = ""
        for character in raw {
            if character.isUppercase, !spaced.isEmpty { spaced.append(" ") }
            spaced.append(character)
        }
        return spaced.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

// MARK: - Settings sections

/// A tab's settings as native form sections.
struct SettingsSectionsView: View {
    let sections: [SettingsSectionDef]
    @Bindable var draft: EnvironmentSettingsDraft

    var body: some View {
        ForEach(sections) { section in
            let visible = section.fields.filter(draft.isVisible)
            if !visible.isEmpty {
                Section(section.title) {
                    ForEach(visible) { field in
                        SettingFieldRow(field: field, draft: draft)
                    }
                }
            }
        }
    }
}

// MARK: - Server-wide settings page

/// A standalone settings page (Timeouts, Activity History), saved on the local
/// environment like the web's server-wide Settings pages.
struct SettingsCategoryView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let category: SettingsCategoryDef
    @State private var draft: EnvironmentSettingsDraft

    init(category: SettingsCategoryDef, environmentID: EnvironmentID = .localDocker, environmentName: String = "") {
        self.category = category
        _draft = State(
            initialValue: EnvironmentSettingsDraft(environmentID: environmentID, environmentName: environmentName))
    }

    var body: some View {
        Form {
            SettingsSectionsView(sections: category.sections, draft: draft)
            if let error = draft.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
        .settingsSaveBar(
            hasChanges: draft.hasChanges,
            isSaving: draft.isSaving,
            isInteractionDisabled: draft.isLoading,
            onSave: { Task { await save() } },
            onRevert: draft.revert
        )
        .task { await load() }
        .refreshable { await load() }
        .overlay {
            if draft.isLoading && !draft.hasLoaded { ProgressView("Loading…") }
        }
    }

    private func load() async {
        guard let client = manager.client else { return }
        await draft.load(client: client, fields: category.fields)
    }

    private func save() async {
        guard let client = manager.client else { return }
        if await draft.save(client: client, fields: category.fields) {
            showToast(.success("Settings saved"))
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
        let orphaned =
            selectedNames
            .subtracting(runningNames)
            .sorted()
            .map { Row(name: $0, isRunning: false) }
        return running + orphaned
    }

    private func filteredRows(from rows: [Row]) -> [Row] {
        guard !search.isEmpty else { return rows }
        return rows.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        let rows = allRows
        let displayedRows = filteredRows(from: rows)
        List {
            if rows.isEmpty {
                ContentUnavailableView(
                    "No Containers",
                    systemImage: "shippingbox",
                    description: Text("Running containers will appear here to exclude from this job.")
                )
            } else {
                Section {
                    ForEach(displayedRows) { row in
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
