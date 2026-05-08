import SwiftUI
import Arcane

struct NotificationSettingsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var configuredProviders: [NotificationResponse] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    // Apprise state
    @State private var appriseApiUrl = ""
    @State private var appriseEnabled = false
    @State private var appriseImageUpdateTag = ""
    @State private var appriseContainerUpdateTag = ""
    @State private var appriseLoaded = false
    @State private var appriseSaving = false
    @State private var appriseTesting = false
    @State private var appriseTestResult: String?

    private func configuredResponse(for provider: NotificationProvider) -> NotificationResponse? {
        configuredProviders.first { $0.provider == provider.rawValue }
    }

    var body: some View {
        Group {
            if isLoading && configuredProviders.isEmpty {
                ProgressView("Loading notifications…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    providersSection
                    appriseSection
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Notifications")
        .task {
            await loadProviders()
            await loadApprise()
        }
        .refreshable {
            await loadProviders()
            await loadApprise()
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Providers Section

    @ViewBuilder
    private var providersSection: some View {
        Section {
            ForEach(NotificationProvider.allCases) { provider in
                let existing = configuredResponse(for: provider)
                NavigationLink(destination: NotificationProviderFormView(
                    provider: provider,
                    existing: existing,
                    onSaved: { await loadProviders() }
                )) {
                    HStack(spacing: 12) {
                        Image(systemName: provider.systemImage)
                            .foregroundStyle(provider.iconColor)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.displayName)
                            if let existing {
                                Text(existing.enabled ? "Enabled" : "Disabled")
                                    .font(.caption)
                                    .foregroundStyle(existing.enabled ? .green : .secondary)
                            } else {
                                Text("Not Configured")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .swipeActions(edge: .trailing) {
                    if existing != nil {
                        Button(role: .destructive) {
                            Task { await deleteProvider(provider) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        } header: {
            Text("Notification Providers")
        } footer: {
            Text("Configure providers to receive notifications for container events.")
        }
    }

    // MARK: - Apprise Section

    @ViewBuilder
    private var appriseSection: some View {
        Section {
            Toggle("Enabled", isOn: $appriseEnabled)
            TextField("API URL", text: $appriseApiUrl)
                .keyboardType(.URL)
                .textContentType(.URL)
                .autocapitalization(.none)
            TextField("Image Update Tag", text: $appriseImageUpdateTag)
                .autocapitalization(.none)
            TextField("Container Update Tag", text: $appriseContainerUpdateTag)
                .autocapitalization(.none)

            HStack {
                Button {
                    Task { await saveApprise() }
                } label: {
                    if appriseSaving {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Text("Save")
                    }
                }
                .disabled(appriseSaving || appriseApiUrl.isEmpty)

                Spacer()

                Button("Test") {
                    Task { await testApprise() }
                }
                .disabled(appriseTesting || !appriseEnabled || appriseApiUrl.isEmpty)
            }

            if let result = appriseTestResult {
                Label(result, systemImage: result.contains("Success") ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(result.contains("Success") ? .green : .red)
                    .font(.caption)
            }
        } header: {
            Text("Apprise")
        } footer: {
            Text("Connect to an Apprise API instance for additional notification providers.")
        }
    }

    // MARK: - API

    private func loadProviders() async {
        guard let client = manager.client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let path = client.rest.environmentPath(manager.activeEnvironmentID, "notifications/settings")
            let rawData = try await client.transport.rawRequest(path, body: Optional<String>.none)
            configuredProviders = try JSONDecoder().decode([NotificationResponse].self, from: rawData)
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func deleteProvider(_ provider: NotificationProvider) async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(manager.activeEnvironmentID, "notifications/settings/\(provider.rawValue)")
            let _: DataResponse<String> = try await client.rest.delete(path)
            configuredProviders.removeAll { $0.provider == provider.rawValue }
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func loadApprise() async {
        guard let client = manager.client, !appriseLoaded else { return }
        do {
            let path = client.rest.environmentPath(manager.activeEnvironmentID, "notifications/apprise")
            let rawData = try await client.transport.rawRequest(path, body: Optional<String>.none)
            let response = try JSONDecoder().decode(AppriseResponse.self, from: rawData)
            appriseApiUrl = response.apiUrl
            appriseEnabled = response.enabled
            appriseImageUpdateTag = response.imageUpdateTag
            appriseContainerUpdateTag = response.containerUpdateTag
            appriseLoaded = true
        } catch {}
    }

    private func saveApprise() async {
        guard let client = manager.client else { return }
        appriseSaving = true
        defer { appriseSaving = false }
        do {
            let body = AppriseUpdate(
                apiUrl: appriseApiUrl,
                containerUpdateTag: appriseContainerUpdateTag,
                enabled: appriseEnabled,
                imageUpdateTag: appriseImageUpdateTag
            )
            let path = client.rest.environmentPath(manager.activeEnvironmentID, "notifications/apprise")
            let rawData = try await client.transport.rawRequest(path, method: "POST", body: body)
            let _ = try JSONDecoder().decode(AppriseResponse.self, from: rawData)
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func testApprise() async {
        guard let client = manager.client else { return }
        appriseTesting = true
        appriseTestResult = nil
        defer { appriseTesting = false }
        do {
            let path = client.rest.environmentPath(manager.activeEnvironmentID, "notifications/apprise/test")
            let _: DataResponse<String> = try await client.rest.post(path, body: String?.none)
            appriseTestResult = "Success — test notification sent"
        } catch {
            appriseTestResult = friendlyErrorMessage(error)
        }
    }
}
