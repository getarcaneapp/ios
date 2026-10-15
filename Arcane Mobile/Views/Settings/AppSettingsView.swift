import Arcane
import SwiftUI

struct AppSettingsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(EnvironmentsStore.self) private var environmentsStore: EnvironmentsStore?
    @AppStorage("arcane.rememberLastTab") private var rememberLastTab = true
    @AppStorage(LiveStatsLimit.preferenceKey) private var liveStatsLimit = LiveStatsLimit.defaultValue
    @AppStorage("arcane.activityToastScope")
    private var activityToastScopeRawValue = ActivityToastScope.userInitiated.rawValue
    @State private var pendingDestructive: PendingDestructive?
    @State private var cacheSizeBytes: Int = 0
    @State private var push = PushNotificationCoordinator.shared

    /// Both of this screen's destructive confirmations route through a single
    /// `.deleteConfirmation` cover (only one full-screen cover can be active per
    /// view), distinguished by this case.
    private enum PendingDestructive {
        case clearCache
    }

    private var appVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var appBuildString: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    private var cacheSizeText: String {
        cacheSizeBytes > 0 ? Int64(cacheSizeBytes).byteString : "Empty"
    }

    var body: some View {
        List {
            generalSection
            dashboardSection
            notificationsSection
            supportSection
            storageSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("App Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshCacheSize() }
        .task(id: manager.clientGeneration) {
            await push.refreshAuthorizationStatus()
            await push.refreshServerStatus(manager: manager)
        }
        .deleteConfirmation(item: $pendingDestructive) { action in
            switch action {
            case .clearCache:
                return DeleteConfirmationConfig(
                    title: "Clear Cache?",
                    message: cacheSizeBytes > 0
                        ? "This will remove \(Int64(cacheSizeBytes).byteString) of cached images. "
                            + "Everything will be re-fetched as needed."
                        : "This will clear all cached images.",
                    icon: "trash",
                    actions: [
                        DeleteConfirmationAction(title: "Clear Cache") {
                            Task {
                                await ImageCache.shared.clear()
                                await AvatarDiskCache.clear()
                                await ResponseCache.shared.invalidateAll()
                                BusiestContainersStore.shared.clearCache()
                                await refreshCacheSize()
                                showToast(.success("Cache cleared"))
                            }
                        }
                    ]
                )
            }
        }
    }

    private var generalSection: some View {
        Section("General") {
            NavigationLink(destination: AppearanceSettingsView()) {
                SettingsRow(title: "Appearance", systemImage: "paintbrush.fill", color: .pink)
            }
            Toggle(isOn: $rememberLastTab) {
                SettingsRow(title: "Remember Last Tab", systemImage: "arrow.uturn.backward.square", color: .indigo)
            }
        }
    }

    private var dashboardSection: some View {
        Section {
            Picker(selection: $liveStatsLimit) {
                ForEach(LiveStatsLimit.choices, id: \.self) { choice in
                    Text(LiveStatsLimit.title(choice)).tag(choice)
                }
            } label: {
                SettingsRow(title: "Live Stats Environments", systemImage: "waveform.path.ecg", color: .green)
            }
            .pickerStyle(.menu)
            .onChange(of: liveStatsLimit) { _, _ in
                environmentsStore?.statsHistory.applyStreamLimit()
            }
        } header: {
            Text("Dashboard")
        } footer: {
            Text("How many environments stream live CPU, memory, and disk on the dashboard. Each keeps a connection open, using more data and battery.")
        }
    }

    private var notificationsSection: some View {
        Section {
            Picker(selection: $activityToastScopeRawValue) {
                ForEach(ActivityToastScope.allCases) { scope in
                    Text(scope.title).tag(scope.rawValue)
                }
            } label: {
                SettingsRow(
                    title: "Activity Toasts",
                    systemImage: "bell.badge.fill",
                    color: .orange
                )
            }
            .pickerStyle(.menu)

            if manager.supportsMobilePush {
                Toggle(isOn: pushEnabledBinding) {
                    SettingsRow(
                        title: "Push Notifications",
                        systemImage: "iphone.radiowaves.left.and.right",
                        color: .blue
                    )
                }
                .disabled(push.isBusy || !pushAvailable)
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text(notificationsFooter)
        }
    }

    private var pushAvailable: Bool {
        push.serverStatus?.enabled == true && !push.isAuthorizationDenied
    }

    private var pushEnabledBinding: Binding<Bool> {
        Binding(
            get: { push.isEnabled(for: manager.serverOrigin) },
            set: { enabled in
                Task { enabled ? await push.enable(manager: manager) : await push.disable(manager: manager) }
            }
        )
    }

    private var notificationsFooter: String {
        let scope = activityToastScope.subtitle
        let toasts = "Toasts show \(scope.prefix(1).lowercased() + scope.dropFirst())."
        guard manager.supportsMobilePush else { return toasts }
        if push.serverStatus?.enabled != true {
            return toasts + " Push is turned off on your Arcane server."
        }
        if push.isAuthorizationDenied {
            return toasts + " Notifications are off in iOS Settings."
        }
        return toasts
    }

    private var activityToastScope: ActivityToastScope {
        ActivityToastScope(rawValue: activityToastScopeRawValue) ?? .userInitiated
    }

    private var storageSection: some View {
        Section {
            Button(role: .destructive) {
                pendingDestructive = .clearCache
            } label: {
                HStack {
                    SettingsRow(
                        title: "Clear Cache",
                        systemImage: "trash",
                        color: .red,
                        titleColor: .red
                    )
                    Spacer()
                    Text(cacheSizeText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Storage")
        } footer: {
            VStack(alignment: .leading, spacing: 20) {
                Text("Cached images are re-fetched as needed.")
                versionFooter
            }
        }
    }

    private var supportSection: some View {
        Section("Support") {
            if let docsURL = URL(string: "https://getarcane.app") {
                Link(destination: docsURL) {
                    SettingsExternalRow(title: "Documentation", systemImage: "globe", color: .blue)
                }
            }
            if let issuesURL = URL(string: "https://github.com/getarcaneapp/ios/issues") {
                Link(destination: issuesURL) {
                    SettingsExternalRow(
                        title: "Report an Issue",
                        systemImage: "exclamationmark.bubble",
                        color: .orange
                    )
                }
            }
            if let discordURL = URL(string: "https://discord.gg/WyXYpdyV3Z") {
                Link(destination: discordURL) {
                    SettingsExternalRow(
                        title: "Join the Discord",
                        systemImage: "bubble.left.and.bubble.right.fill",
                        color: .indigo
                    )
                }
            }
            if let privacyURL = URL(string: "https://getarcane.app/privacy") {
                Link(destination: privacyURL) {
                    SettingsExternalRow(title: "Privacy Policy", systemImage: "hand.raised.fill", color: .gray)
                }
            }
            if let coffeeURL = URL(string: "https://buymeacoffee.com/kmendell") {
                Link(destination: coffeeURL) {
                    SettingsExternalRow(
                        title: "Buy Me a Coffee",
                        systemImage: "cup.and.saucer.fill",
                        color: .orange
                    )
                }
            }
        }
    }

    /// Tapping the bottom footer copies the complete version string.
    private var versionFooter: some View {
        Button {
            UIPasteboard.general.string = "\(appVersionString) (\(appBuildString))"
            showToast(.copied("Version copied"))
        } label: {
            VStack(spacing: 2) {
                Text("Arcane Mobile")
                    .fontWeight(.medium)
                Text("Version \(appVersionString) (\(appBuildString))")
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy version \(appVersionString), build \(appBuildString)")
    }

    private func refreshCacheSize() async {
        async let images = ImageCache.shared.diskBytes()
        async let avatars = AvatarDiskCache.diskBytes()
        cacheSizeBytes = await images + avatars
    }
}
