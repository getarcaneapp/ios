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
                    selection: $buildProvider,
                    helper: "Choose where Arcane should run image builds."
                ) {
                    Text("Local").tag("local")
                    Text("Depot").tag("depot")
                }
            } header: {
                Label("Provider", systemImage: "hammer")
            }

            Section("Configuration") {
                FormTextField(
                    title: "Build Timeout",
                    placeholder: "1800",
                    text: $buildTimeout,
                    keyboardType: .numberPad,
                    helper: "Maximum build duration in seconds."
                )
                FormTextField(
                    title: "Builds Directory",
                    placeholder: "/path/to/builds",
                    text: $buildsDirectory,
                    autocapitalization: .never,
                    autocorrectionDisabled: true,
                    monospaced: true
                )
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
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            var body = UpdateSettings()
            body.buildProvider = buildProvider
            body.buildsDirectory = buildsDirectory.isEmpty ? nil : buildsDirectory
            body.buildTimeout = buildTimeout
            body.depotProjectId = buildProvider == "depot" ? (depotProjectId.isEmpty ? nil : depotProjectId) : nil
            body.depotToken = buildProvider == "depot" ? (depotToken.isEmpty ? nil : depotToken) : nil
            let path = client.rest.environmentPath(manager.activeEnvironmentID, "settings")
            let _: [PublicSetting] = try await client.rest.put(path, body: body)
            showToast(.success("Build settings saved"))
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
