import SwiftUI
import Arcane

struct AppSettingsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var pendingDestructive: PendingDestructive?
    @State private var showCacheCleared = false
    @State private var cacheSizeBytes: Int = 0
    @State private var showWhatsNew = false

    /// Both of this screen's destructive confirmations route through a single
    /// `.deleteConfirmation` cover (only one full-screen cover can be active per
    /// view), distinguished by this case.
    private enum PendingDestructive {
        case changeServer
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
            applicationSection
            aboutSection
            supportSection
            versionSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("App Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshCacheSize() }
        .alert("Cache Cleared", isPresented: $showCacheCleared) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Cached images and API responses will be reloaded from the server.")
        }
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView()
        }
        .deleteConfirmation(item: $pendingDestructive) { action in
            switch action {
            case .changeServer:
                return DeleteConfirmationConfig(
                    title: "Change Server?",
                    message: "You'll be signed out and asked for a new server URL.",
                    icon: "link",
                    actions: [DeleteConfirmationAction(title: "Change Server") {
                        Task { await manager.logout() }
                    }]
                )
            case .clearCache:
                return DeleteConfirmationConfig(
                    title: "Clear Cache?",
                    message: cacheSizeBytes > 0
                        ? "This will remove \(Int64(cacheSizeBytes).byteString) of cached images and API data. Everything will be re-fetched as needed."
                        : "This will clear all cached images and API data.",
                    icon: "trash",
                    actions: [DeleteConfirmationAction(title: "Clear Cache") {
                        Task {
                            await ImageCache.shared.clear()
                            await ResponseCache.shared.invalidateAll()
                            await refreshCacheSize()
                            showCacheCleared = true
                        }
                    }]
                )
            }
        }
    }

    @ViewBuilder
    private var applicationSection: some View {
        Section("Application") {
            NavigationLink(destination: AppearanceSettingsView()) {
                SettingsRow(title: "Appearance", systemImage: "paintbrush.fill", color: .pink)
            }
            Button {
                pendingDestructive = .changeServer
            } label: {
                HStack {
                    SettingsRow(
                        title: "Server",
                        subtitle: serverURLText,
                        systemImage: "link",
                        color: .blue,
                        titleColor: .primary
                    )
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
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
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        Section("About") {
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
    }

    @ViewBuilder
    private var versionSection: some View {
        Section("Version") {
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
            HStack {
                SettingsRow(title: "Version", systemImage: "app.badge", color: .gray)
                Spacer()
                Text(appVersionString)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack {
                SettingsRow(title: "Build", systemImage: "hammer", color: .gray)
                Spacer()
                Text(appBuildString)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func refreshCacheSize() async {
        async let images = ImageCache.shared.diskBytes()
        async let responses = ResponseCache.shared.diskBytes()
        cacheSizeBytes = await images + responses
    }
}
