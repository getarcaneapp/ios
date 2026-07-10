import SwiftUI
import Arcane

struct AppSettingsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @AppStorage("arcane.showAssistantButton") private var showAssistantButton = true
    @AppStorage("arcane.rememberLastTab") private var rememberLastTab = true
    @State private var pendingDestructive: PendingDestructive?
    @State private var cacheSizeBytes: Int = 0
    @State private var showWhatsNew = false

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
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView()
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
            if #available(iOS 26, *), AIAvailability.canExposeAssistant {
                Toggle(isOn: $showAssistantButton) {
                    SettingsRow(title: "Arcane Assistant", systemImage: "sparkles", color: .pink)
                }
            }
        }
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
                showWhatsNew = true
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
            Link(destination: URL(string: "https://getarcane.app")!) {
                SettingsExternalRow(title: "Documentation", systemImage: "globe", color: .blue)
            }
            ShareLink(item: URL(string: "https://getarcane.app")!) {
                SettingsRow(
                    title: "Share Arcane",
                    systemImage: "square.and.arrow.up",
                    color: .blue,
                    titleColor: .primary
                )
            }
            Link(destination: URL(string: "https://getarcane.app/privacy")!) {
                SettingsExternalRow(title: "Privacy Policy", systemImage: "hand.raised.fill", color: .gray)
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
        .contentShape(Rectangle())
        .onTapGesture {
            UIPasteboard.general.string = "\(appVersionString) (\(appBuildString))"
            showToast(.copied("Version copied"))
        }
    }

    @ViewBuilder
    private var supportRows: some View {
        Link(destination: URL(string: "https://buymeacoffee.com/kmendell")!) {
            SettingsExternalRow(title: "Buy Me a Coffee", systemImage: "cup.and.saucer.fill", color: .orange)
        }
        Link(destination: URL(string: "https://discord.gg/WyXYpdyV3Z")!) {
            SettingsExternalRow(
                title: "Join the Discord",
                systemImage: "bubble.left.and.bubble.right.fill",
                color: .indigo
            )
        }
        Link(destination: URL(string: "https://github.com/getarcaneapp/ios/issues")!) {
            SettingsExternalRow(title: "Report an Issue", systemImage: "exclamationmark.bubble", color: .orange)
        }
    }

    private func refreshCacheSize() async {
        async let images = ImageCache.shared.diskBytes()
        async let responses = ResponseCache.shared.diskBytes()
        cacheSizeBytes = await images + responses
    }
}
