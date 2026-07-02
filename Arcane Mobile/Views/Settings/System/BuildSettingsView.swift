import SwiftUI
import Arcane

struct BuildSettingsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager

    @State private var buildProvider = "local"
    @State private var buildTimeout = "1800"
    @State private var buildsDirectory = ""
    @State private var depotProjectId = ""
    @State private var depotToken = ""

    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                FormPicker(
                    title: "Build Provider",
                    selection: $buildProvider
                ) {
                    Text("Local").tag("local")
                    Text("Depot").tag("depot")
                }
            } header: {
                Label("Provider", systemImage: "hammer")
            } footer: {
                Text("Choose where Arcane should run image builds.")
            }

            Section {
                FormNumberField(
                    title: "Build Timeout",
                    placeholder: "1800",
                    text: $buildTimeout,
                    minValue: 60,
                    maxValue: 14400
                )
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
                Text("Configuration")
            } footer: {
                Text("Build duration in seconds (60–14400).")
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
                    Label("Depot Credentials", systemImage: "key")
                }
            }

            if let error = errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Spacer()
                        if isSaving {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Text("Save")
                        }
                        Spacer()
                    }
                }
                .disabled(isSaving)
            }
        }
        .navigationTitle("Builds")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSettings() }
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
            let dict = Dictionary(dtos.map { ($0.key, $0.value) }, uniquingKeysWith: { _, new in new })
            buildProvider = dict["buildProvider"] ?? "local"
            buildTimeout = dict["buildTimeout"] ?? "1800"
            buildsDirectory = dict["buildsDirectory"] ?? ""
            depotProjectId = dict["depotProjectId"] ?? ""
            depotToken = dict["depotToken"] ?? ""
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
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
            let path = client.rest.environmentPath(manager.activeEnvironmentID, "settings")
            let _: [PublicSetting] = try await client.rest.put(path, body: body)
            showToast(.success("Build settings saved"))
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
