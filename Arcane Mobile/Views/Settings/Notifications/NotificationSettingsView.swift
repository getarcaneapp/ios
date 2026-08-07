import SwiftUI
import Arcane

struct NotificationSettingsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var configuredProviders: [NotificationSettings] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var pendingDeleteProvider: NotificationProvider?

    private func configuredResponse(for provider: NotificationProvider) -> NotificationSettings? {
        configuredProviders.first { $0.provider == provider }
    }

    private var availableProviders: [NotificationProvider] {
        notificationProviders(supportsPost26Features: manager.supportsPost26MobileFeatures)
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
        .deleteConfirmation(
            item: $pendingDeleteProvider,
            title: { _ in "Delete Provider" },
            message: { "Remove the “\($0.displayName)” notification provider? You'll stop receiving its notifications." },
            icon: "trash",
            confirmTitle: "Delete",
            onConfirm: { provider in Task { await deleteProvider(provider) } }
        )
    }

    // MARK: - Providers Section

    @ViewBuilder
    private var providersSection: some View {
        Section {
            ForEach(availableProviders) { provider in
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
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if existing != nil {
                        Button {
                            pendingDeleteProvider = provider
                        } label: {
                            Label("Delete", systemImage: "trash")
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
            configuredProviders = try await client.notifications.listSettings(
                envID: manager.activeEnvironmentID
            )
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func deleteProvider(_ provider: NotificationProvider) async {
        guard let client = manager.client else { return }
        do {
            try await client.notifications.deleteSettings(
                provider: provider,
                envID: manager.activeEnvironmentID
            )
            configuredProviders.removeAll { $0.provider == provider }
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

func notificationProviders(supportsPost26Features: Bool) -> [NotificationProvider] {
    NotificationProvider.allCases.filter {
        $0 != .googlechat || supportsPost26Features
    }
}
