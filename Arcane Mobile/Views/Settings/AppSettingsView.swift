import SwiftUI
import Arcane

struct AppSettingsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @AppStorage("arcane.showAssistantButton") private var showAssistantButton = true
    @State private var pendingDestructive: PendingDestructive?
    @State private var cacheSizeBytes: Int = 0
    @State private var showWhatsNew = false
    @State private var serverVersion: ServerVersionInfo?
    @State private var isLoadingServerVersion = false

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
            serverVersionSection
            aboutSection
            supportSection
            versionSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("App Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshCacheSize() }
        .task { await loadServerVersion() }
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
                            showToast(.success("Cache cleared"))
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
        if #available(iOS 26, *) {
            Section("AI Assistant") {
                Toggle(isOn: $showAssistantButton) {
                    SettingsRow(title: "Show AI Button", systemImage: "sparkles", color: .pink)
                }
            }
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
    private var serverVersionSection: some View {
        if let v = serverVersion {
            Section("Arcane Server") {
                serverRow("Version", value: clean(v.displayVersion) ?? clean(v.currentVersion),
                          icon: "shippingbox.fill", color: .blue)
                if let tag = clean(v.currentTag) {
                    serverRow("Image Tag", value: tag, icon: "tag.fill", color: .purple)
                }
                if let node = clean(v.nodeVersion) {
                    serverRow("Node", value: node, icon: "leaf.fill", color: .green)
                }
                if let sk = clean(v.svelteKitVersion) {
                    serverRow("SvelteKit", value: sk, icon: "bolt.fill", color: .orange)
                }
                if let go = clean(v.goVersion) {
                    serverRow("Go", value: go, icon: "g.circle.fill", color: .teal)
                }
                if let rev = clean(v.shortRevision) {
                    serverRow("Revision", value: rev, copy: v.revision ?? rev,
                              icon: "number", color: .gray, mono: true)
                }
                if let bt = clean(v.buildTime) {
                    serverRow("Build Time", value: bt, icon: "clock.fill", color: .gray)
                }
                if v.updateAvailable == true, let newest = clean(v.newestVersion) {
                    serverRow("Update Available", value: newest,
                              icon: "arrow.up.circle.fill", color: .blue)
                }
            }
        } else if isLoadingServerVersion {
            Section("Arcane Server") {
                HStack {
                    Text("Loading…").foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                }
            }
        }
    }

    @ViewBuilder
    private func serverRow(_ title: String, value: String?, copy: String? = nil,
                           icon: String, color: Color, mono: Bool = false) -> some View {
        let display = value ?? "—"
        Button {
            UIPasteboard.general.string = copy ?? display
            showToast(.copied("\(title) copied"))
        } label: {
            HStack {
                SettingsRow(title: title, systemImage: icon, color: color)
                Spacer()
                Text(display)
                    .font(mono ? .subheadline.monospaced() : .subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Treats nil/empty/`"unknown"` as absent so those rows are hidden, matching
    /// the web "About Arcane" dialog.
    private func clean(_ s: String?) -> String? {
        guard let s, !s.isEmpty, s != "unknown" else { return nil }
        return s
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

    private func loadServerVersion() async {
        guard let client = manager.client, serverVersion == nil else { return }
        isLoadingServerVersion = true
        defer { isLoadingServerVersion = false }
        do {
            let data = try await client.transport.rawRequest(
                "app-version", body: Optional<String>.none, authorized: false)
            serverVersion = try JSONDecoder().decode(ServerVersionInfo.self, from: data)
        } catch {
            // Leave nil — section hides itself. No error UI for optional metadata.
        }
    }
}
