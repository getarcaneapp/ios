import SwiftUI
import Arcane

// MARK: - Settings Category Definitions

struct SettingFieldDef: Identifiable {
    let key: String
    let label: String
    let type: SettingFieldType
    var description: String? = nil
    var id: String { key }
}

enum SettingFieldType {
    case text
    case number
    case boolean
    case password
    case select([String])
    case cron
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
            .init(key: "baseServerUrl", label: "Base Server URL", type: .text),
            .init(key: "diskUsagePath", label: "Disk Usage Path", type: .text),
            .init(key: "enableGravatar", label: "Enable Gravatar", type: .boolean),
            .init(key: "defaultShell", label: "Default Shell", type: .text),
            .init(key: "autoInjectEnv", label: "Auto-Inject .env", type: .boolean),
            .init(key: "defaultDeployPullPolicy", label: "Default Pull Policy", type: .select(["always", "missing", "never", "build"])),
        ]
    ),
    .init(
        id: "docker",
        title: "Docker Daemon",
        icon: "shippingbox",
        summary: "Docker host and project directories",
        fields: [
            .init(key: "dockerHost", label: "Docker Host", type: .text),
            .init(key: "projectsDirectory", label: "Projects Directory", type: .text),
            .init(key: "swarmStackSourcesDirectory", label: "Swarm Stack Sources", type: .text),
            .init(key: "followProjectSymlinks", label: "Follow Project Symlinks", type: .boolean),
            .init(key: "dockerPruneMode", label: "Prune Mode", type: .select(["all", "dangling"])),
        ]
    ),
    .init(
        id: "auto-update",
        title: "Auto-Update",
        icon: "arrow.triangle.2.circlepath",
        summary: "Automatic image updates and polling",
        fields: [
            .init(key: "autoUpdate", label: "Enabled", type: .boolean),
            .init(key: "autoUpdateExcludedContainers", label: "Excluded Containers", type: .text),
            .init(key: "pollingEnabled", label: "Polling Enabled", type: .boolean),
        ]
    ),
    .init(
        id: "auto-heal",
        title: "Auto-Heal",
        icon: "heart.text.square",
        summary: "Restart unhealthy containers automatically",
        fields: [
            .init(key: "autoHealEnabled", label: "Enabled", type: .boolean),
            .init(key: "autoHealMaxRestarts", label: "Max Restarts", type: .number),
            .init(key: "autoHealRestartWindow", label: "Restart Window (min)", type: .number),
            .init(key: "autoHealExcludedContainers", label: "Excluded Containers", type: .text),
        ]
    ),
    .init(
        id: "prune",
        title: "Scheduled Pruning",
        icon: "trash.circle",
        summary: "Automatically clean up unused resources",
        fields: [
            .init(key: "scheduledPruneEnabled", label: "Enabled", type: .boolean),
            .init(key: "scheduledPruneContainers", label: "Prune Containers", type: .boolean),
            .init(key: "scheduledPruneImages", label: "Prune Images", type: .boolean),
            .init(key: "scheduledPruneVolumes", label: "Prune Volumes", type: .boolean),
            .init(key: "scheduledPruneNetworks", label: "Prune Networks", type: .boolean),
            .init(key: "scheduledPruneBuildCache", label: "Prune Build Cache", type: .boolean),
            .init(key: "pruneContainerMode", label: "Container Mode", type: .select(["none", "stopped", "olderThan"])),
            .init(key: "pruneContainerUntil", label: "Container Until", type: .text),
            .init(key: "pruneImageMode", label: "Image Mode", type: .select(["none", "dangling", "all", "olderThan"])),
            .init(key: "pruneImageUntil", label: "Image Until", type: .text),
            .init(key: "pruneVolumeMode", label: "Volume Mode", type: .select(["none", "anonymous", "all"])),
            .init(key: "pruneNetworkMode", label: "Network Mode", type: .select(["none", "unused", "olderThan"])),
            .init(key: "pruneNetworkUntil", label: "Network Until", type: .text),
            .init(key: "pruneBuildCacheMode", label: "Build Cache Mode", type: .select(["none", "unused", "all", "olderThan"])),
            .init(key: "pruneBuildCacheUntil", label: "Build Cache Until", type: .text),
        ]
    ),
    .init(
        id: "vulnerability",
        title: "Vulnerability Scanning",
        icon: "shield.lefthalf.filled",
        summary: "Trivy scanner configuration",
        fields: [
            .init(key: "vulnerabilityScanEnabled", label: "Enabled", type: .boolean),
            .init(key: "trivyImage", label: "Trivy Image", type: .text),
            .init(key: "trivyNetwork", label: "Network", type: .text),
            .init(key: "trivySecurityOpts", label: "Security Options", type: .text),
            .init(key: "trivyPrivileged", label: "Privileged Mode", type: .boolean),
            .init(key: "trivyResourceLimitsEnabled", label: "Resource Limits", type: .boolean),
            .init(key: "trivyCpuLimit", label: "CPU Limit", type: .text),
            .init(key: "trivyMemoryLimitMb", label: "Memory Limit (MB)", type: .number),
            .init(key: "trivyConcurrentScanContainers", label: "Concurrent Scans", type: .number),
            .init(key: "trivyPreserveCacheOnVolumePrune", label: "Preserve Cache", type: .boolean),
        ]
    ),
    .init(
        id: "timeouts",
        title: "Timeouts",
        icon: "clock",
        summary: "Operation timeouts in seconds",
        fields: [
            .init(key: "dockerApiTimeout", label: "Docker API (s)", type: .number),
            .init(key: "dockerImagePullTimeout", label: "Image Pull (s)", type: .number),
            .init(key: "trivyScanTimeout", label: "Trivy Scan (s)", type: .number),
            .init(key: "gitOperationTimeout", label: "Git Operation (s)", type: .number),
            .init(key: "httpClientTimeout", label: "HTTP Client (s)", type: .number),
            .init(key: "registryTimeout", label: "Registry (s)", type: .number),
            .init(key: "proxyRequestTimeout", label: "Proxy Request (s)", type: .number),
            .init(key: "buildTimeout", label: "Build (s)", type: .number),
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

    var body: some View {
        List {
            Section {
                ForEach(systemSettingsCategories) { category in
                    NavigationLink(destination: SettingsCategoryView(category: category)) {
                        SettingsCategoryRow(category: category)
                    }
                }
            } footer: {
                Text("Settings apply to the active environment: \(manager.activeEnvironmentName)")
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
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var savedMessage: String?

    private var hasChanges: Bool {
        category.fields.contains { settings[$0.key] != originalSettings[$0.key] }
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

            if let msg = savedMessage {
                Section {
                    Label(msg, systemImage: "checkmark.circle").foregroundStyle(.green)
                }
            }
        }
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSettings() }
        .refreshable { await loadSettings() }
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

        VStack(alignment: .leading, spacing: 0) {
            switch field.type {
            case .boolean:
                Toggle(field.label, isOn: boolBinding)
            case .number:
                HStack {
                    Text(field.label)
                    Spacer()
                    TextField("", text: binding)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 100)
                        .foregroundStyle(.secondary)
                }
            case .password:
                SecureField(field.label, text: binding)
            case .select(let options):
                let pickerBinding = Binding<String>(
                    get: {
                        let current = settings[field.key] ?? ""
                        return options.contains(current) ? current : (options.first ?? "")
                    },
                    set: { settings[field.key] = $0 }
                )
                Picker(field.label, selection: pickerBinding) {
                    ForEach(options, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
            case .cron:
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.label)
                    TextField("* * * * *", text: binding)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .autocapitalization(.none)
                }
            case .text:
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.label)
                    TextField("", text: binding)
                        .foregroundStyle(.secondary)
                        .autocapitalization(.none)
                }
            }
            if let description = field.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
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

    private func saveSettings() async {
        guard let client = manager.client else { return }
        isSaving = true
        errorMessage = nil
        savedMessage = nil
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
            let jsonData = try JSONSerialization.data(withJSONObject: changedPairs)
            var update = try JSONDecoder().decode(SettingsUpdate.self, from: jsonData)
            update._dollar_schema = nil
            let path = client.rest.environmentPath(manager.activeEnvironmentID, "settings")
            let _: [PublicSetting] = try await client.rest.put(path, body: update)
            for (key, value) in changedPairs {
                originalSettings[key] = value
            }
            savedMessage = "Settings saved"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { savedMessage = nil }
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
