import SwiftUI
import Arcane
import WhatsNewKit

struct AppSettingsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @AppStorage("arcane.rememberLastTab") private var rememberLastTab = true
    @AppStorage("arcane.activityToastScope")
    private var activityToastScopeRawValue = ActivityToastScope.userInitiated.rawValue
    @State private var pendingDestructive: PendingDestructive?
    @State private var cacheSizeBytes: Int = 0
    @State private var presentedWhatsNew: WhatsNewKit.WhatsNew?
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

    private var serverURLText: String {
        manager.serverURL.isEmpty ? "Not configured" : manager.serverURL
    }

    var body: some View {
        List {
            generalSection
            activityNotificationsSection
            serverSection
            aboutSection
            supportSection
            // Danger zone — destructive actions stay at the very bottom.
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
        .sheet(item: $presentedWhatsNew) { whatsNew in
            WhatsNewPresentationView(whatsNew: whatsNew)
        }
        .deleteConfirmation(item: $pendingDestructive) { action in
            switch action {
            case .clearCache:
                return DeleteConfirmationConfig(
                    title: "Clear Cache?",
                    message: cacheSizeBytes > 0
                        ? "This will remove \(Int64(cacheSizeBytes).byteString) of cached images and API data. "
                            + "Everything will be re-fetched as needed."
                        : "This will clear all cached images and API data.",
                    icon: "trash",
                    actions: [DeleteConfirmationAction(title: "Clear Cache") {
                        Task {
                            await ImageCache.shared.clear()
                            await ResponseCache.shared.invalidateAll()
                            await refreshCacheSize()
                            showToast(.success("Cache cleared"))
                        }
                    }]
                )
            }
        }
    }

    @ViewBuilder
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

    @ViewBuilder
    private var activityNotificationsSection: some View {
        Section {
            HStack(spacing: 12) {
                SettingsRow(
                    title: "Activity Toasts",
                    systemImage: "bell.badge.fill",
                    color: .orange
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                Picker("Activity Toasts", selection: $activityToastScopeRawValue) {
                    ForEach(ActivityToastScope.allCases) { scope in
                        Text(scope.title).tag(scope.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Activity Toasts")
                .accessibilityValue(activityToastScope.title)
            }
            if manager.supportsMobilePush {
                Toggle(isOn: pushEnabledBinding) {
                    SettingsRow(
                        title: "Push Notifications",
                        subtitle: push.isEnabled(for: manager.serverOrigin) ? "Enabled on this device" : nil,
                        systemImage: "iphone.radiowaves.left.and.right",
                        color: .blue
                    )
                }
                .disabled(push.isBusy || !pushAvailable)
            }
        } header: {
            Text("Activity Notifications")
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
        let toasts = "\(activityToastScope.subtitle). User Initiated excludes automated and server maintenance activities."
        guard manager.supportsMobilePush else { return toasts }
        if push.serverStatus?.enabled != true {
            return toasts + " Push notifications are turned off by your Arcane admin."
        }
        if push.isAuthorizationDenied {
            return toasts + " Notifications for Arcane are turned off in iOS Settings."
        }
        return toasts + " Push notifications are delivered through Arcane's push relay; only the notification text is sent, never your server address or credentials."
    }

    private var activityToastScope: ActivityToastScope {
        ActivityToastScope(rawValue: activityToastScopeRawValue) ?? .userInitiated
    }

    @ViewBuilder
    private var serverSection: some View {
        Section {
            NavigationLink(destination: ServerInfoView()) {
                SettingsRow(
                    title: "Server Info",
                    subtitle: serverURLText,
                    systemImage: "server.rack",
                    color: .teal
                )
            }
        } header: {
            Text("Server")
        } footer: {
            Text("To change servers, sign out from your Account page.")
        }
    }

    @ViewBuilder
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
            Text("Danger Zone")
        } footer: {
            VStack(alignment: .leading, spacing: 20) {
                Text("Cached images and API responses are re-fetched as needed.")
                versionFooter
            }
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        Section("About") {
            Button {
                presentedWhatsNew = ReleaseNotes.latestWhatsNew
            } label: {
                HStack {
                    SettingsRow(title: "What's New", systemImage: "sparkles", color: .yellow, titleColor: .primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let docsURL = URL(string: "https://getarcane.app") {
                Link(destination: docsURL) {
                    SettingsExternalRow(title: "Documentation", systemImage: "globe", color: .blue)
                }
                ShareLink(item: docsURL) {
                    SettingsRow(
                        title: "Share Arcane",
                        systemImage: "square.and.arrow.up",
                        color: .blue,
                        titleColor: .primary
                    )
                }
            }
            if let privacyURL = URL(string: "https://getarcane.app/privacy") {
                Link(destination: privacyURL) {
                    SettingsExternalRow(title: "Privacy Policy", systemImage: "hand.raised.fill", color: .gray)
                }
            }
        }
    }

    @ViewBuilder
    private var supportSection: some View {
        Section("Support") {
            supportRows
        }
    }

    /// Compact replacement for the old "Version" section rows; tapping copies
    /// the full version string since the rows it replaced were copyable.
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

    @ViewBuilder
    private var supportRows: some View {
        if let coffeeURL = URL(string: "https://buymeacoffee.com/kmendell") {
            Link(destination: coffeeURL) {
                SettingsExternalRow(title: "Buy Me a Coffee", systemImage: "cup.and.saucer.fill", color: .orange)
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
        if let issuesURL = URL(string: "https://github.com/getarcaneapp/ios/issues") {
            Link(destination: issuesURL) {
                SettingsExternalRow(title: "Report an Issue", systemImage: "exclamationmark.bubble", color: .orange)
            }
        }
    }

    private func refreshCacheSize() async {
        async let images = ImageCache.shared.diskBytes()
        async let responses = ResponseCache.shared.diskBytes()
        cacheSizeBytes = await images + responses
    }
}
