import SwiftUI
import Arcane

private struct BuildSettingsFormState: Equatable {
    let buildProvider: String
    let buildTimeout: String
    let buildsDirectory: String
    let depotProjectId: String
    let depotToken: String
}

struct BuildSettingsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager

    let environmentID: EnvironmentID
    let environmentName: String

    @State private var buildProvider = "local"
    @State private var buildTimeout = "1800"
    @State private var buildsDirectory = ""
    @State private var depotProjectId = ""
    @State private var depotToken = ""

    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var originalState: BuildSettingsFormState?

    private var formState: BuildSettingsFormState {
        BuildSettingsFormState(
            buildProvider: buildProvider,
            buildTimeout: buildTimeout,
            buildsDirectory: buildsDirectory,
            depotProjectId: depotProjectId,
            depotToken: depotToken
        )
    }

    private var hasChanges: Bool {
        guard !isLoading, let originalState else { return false }
        return formState != originalState
    }

    var body: some View {
        Form {
            Section {
                FormTextField(
                    title: "Builds Directory",
                    placeholder: "/path/to/builds",
                    text: $buildsDirectory,
                    autocapitalization: .never,
                    autocorrectionDisabled: true,
                    monospaced: true,
                    layout: .stacked
                )
            } header: {
                Label("Build Workspace", systemImage: "folder")
            } footer: {
                Text("Directory used for build workspaces.")
            }

            Section {
                FormPicker(
                    title: "Build Provider",
                    selection: $buildProvider
                ) {
                    Text("Local").tag("local")
                    Text("Depot").tag("depot")
                }
                FormNumberField(
                    title: "Build Timeout",
                    placeholder: "1800",
                    text: $buildTimeout,
                    minValue: 60,
                    maxValue: 14400
                )
            } header: {
                Label("Build Provider", systemImage: "hammer")
            } footer: {
                Text("Choose where Arcane runs image builds. Timeout is in seconds (60–14400).")
            }

            if buildProvider == "depot" {
                Section {
                    FormTextField(
                        title: "Project ID",
                        placeholder: "Depot project ID",
                        text: $depotProjectId,
                        autocapitalization: .never,
                        autocorrectionDisabled: true
                    )
                    FormSecureField(
                        title: "Depot Token",
                        placeholder: "Required for Depot builds",
                        text: $depotToken
                    )
                } header: {
                    Label("Depot", systemImage: "key")
                }
            }

            if let error = errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }

        }
        .navigationTitle("Builds")
        .navigationBarTitleDisplayMode(.inline)
        .settingsSaveBar(
            hasChanges: hasChanges,
            isSaving: isSaving,
            isInteractionDisabled: isLoading,
            onSave: { Task { await save() } },
            onRevert: revertChanges
        )
        .task(id: environmentID.rawValue) {
            await loadSettings()
        }
        .refreshable {
            await loadSettings()
        }
        .overlay {
            if isLoading {
                ProgressView("Loading…")
            }
        }
    }

    // MARK: - API

    private func loadSettings() async {
        guard let client = manager.client else { return }
        isLoading = true
        errorMessage = nil
        originalState = nil
        buildProvider = "local"
        buildTimeout = "1800"
        buildsDirectory = ""
        depotProjectId = ""
        depotToken = ""
        defer { isLoading = false }
        do {
            let path = client.rest.environmentPath(environmentID, "settings")
            let rawData = try await client.transport.rawRequest(path, body: Optional<String>.none)
            let dtos = try JSONDecoder().decode([PublicSetting].self, from: rawData)
            let dict = Dictionary(dtos.map { ($0.key, $0.value) }, uniquingKeysWith: { _, new in new })
            guard !Task.isCancelled else { return }
            buildProvider = dict["buildProvider"] ?? "local"
            buildTimeout = dict["buildTimeout"] ?? "1800"
            buildsDirectory = dict["buildsDirectory"] ?? ""
            depotProjectId = dict["depotProjectId"] ?? ""
            depotToken = dict["depotToken"] ?? ""
            originalState = formState
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func revertChanges() {
        guard let originalState else { return }
        buildProvider = originalState.buildProvider
        buildTimeout = originalState.buildTimeout
        buildsDirectory = originalState.buildsDirectory
        depotProjectId = originalState.depotProjectId
        depotToken = originalState.depotToken
        errorMessage = nil
    }

    private func save() async {
        guard let client = manager.client else { return }

        if let t = Int(buildTimeout.trimmingCharacters(in: .whitespaces)), t < 60 || t > 14400 {
            errorMessage = "Build Timeout must be between 60 and 14400 seconds."
            return
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            // Settings are flat string key/values server-side; send a raw dict instead of
            // the SDK's UpdateSettings struct.
            var body: [String: String] = [
                "buildProvider": buildProvider,
                "buildTimeout": buildTimeout,
            ]
            let trimmedDir = buildsDirectory.trimmingCharacters(in: .whitespaces)
            if !trimmedDir.isEmpty { body["buildsDirectory"] = trimmedDir }
            if buildProvider == "depot" {
                let trimmedProject = depotProjectId.trimmingCharacters(in: .whitespaces)
                if !trimmedProject.isEmpty { body["depotProjectId"] = trimmedProject }
                if !depotToken.isEmpty { body["depotToken"] = depotToken }
            }
            let path = client.rest.environmentPath(environmentID, "settings")
            let _: [PublicSetting] = try await client.rest.put(path, body: body)
            guard !Task.isCancelled else { return }
            originalState = formState
            showToast(.success("Build settings saved for \(environmentName)"))
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
