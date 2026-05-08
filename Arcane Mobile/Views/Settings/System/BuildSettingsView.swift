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
    @State private var savedMessage: String?

    var body: some View {
        Form {
            Section {
                Picker("Build Provider", selection: $buildProvider) {
                    Text("Local").tag("local")
                    Text("Depot").tag("depot")
                }
            } header: {
                Label("Provider", systemImage: "hammer")
            }

            Section("Configuration") {
                HStack {
                    Text("Build Timeout (s)")
                    Spacer()
                    TextField("1800", text: $buildTimeout)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 100)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Builds Directory")
                    Spacer()
                    TextField("/path/to/builds", text: $buildsDirectory)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                        .autocapitalization(.none)
                }
            }

            if buildProvider == "depot" {
                Section {
                    TextField("Project ID", text: $depotProjectId)
                        .autocapitalization(.none)
                    SecureField("Depot Token", text: $depotToken)
                } header: {
                    Label("Depot Credentials", systemImage: "key")
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
            let dict = Dictionary(uniqueKeysWithValues: dtos.map { ($0.key, $0.value) })
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
        savedMessage = nil
        defer { isSaving = false }
        do {
            let body = SettingsUpdate(
                buildProvider: buildProvider,
                buildTimeout: buildTimeout,
                buildsDirectory: buildsDirectory.isEmpty ? nil : buildsDirectory,
                depotProjectId: buildProvider == "depot" ? (depotProjectId.isEmpty ? nil : depotProjectId) : nil,
                depotToken: buildProvider == "depot" ? (depotToken.isEmpty ? nil : depotToken) : nil
            )
            let path = client.rest.environmentPath(manager.activeEnvironmentID, "settings")
            let _: [PublicSetting] = try await client.rest.put(path, body: body)
            savedMessage = "Build settings saved"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { savedMessage = nil }
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
