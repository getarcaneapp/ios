import SwiftUI
import Arcane

struct NotificationSettingsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var configuredProviders: [NotificationSettings] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private func configuredResponse(for provider: NotificationProvider) -> NotificationSettings? {
        configuredProviders.first { $0.provider == provider }
    }

    var body: some View {
        Group {
            if isLoading && configuredProviders.isEmpty {
                ProgressView("Loading notifications…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    providersSection
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Notifications")
        .task {
            await loadProviders()
        }
        .refreshable {
            await loadProviders()
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
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
                            DestructiveLabel(text: "Delete")
                        }
                        .tint(.red)
                    }
                }
            }
        } header: {
            Text("Notification Providers")
        } footer: {
            Text("Configure providers to receive notifications for container events.")
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
            configuredProviders = try JSONDecoder().decode([NotificationSettings].self, from: rawData)
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func deleteProvider(_ provider: NotificationProvider) async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(manager.activeEnvironmentID, "notifications/settings/\(provider.rawValue)")
            try await client.rest.deleteVoid(path)
            configuredProviders.removeAll { $0.provider == provider }
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
