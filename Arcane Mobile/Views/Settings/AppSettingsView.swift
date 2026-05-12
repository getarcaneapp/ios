import SwiftUI

struct AppSettingsView: View {
    @State private var showClearCacheConfirm = false
    @State private var showCacheCleared = false
    @State private var cacheSizeBytes: Int = 0
    @State private var showWhatsNew = false

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
            applicationSection
            aboutSection
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
    }

    @ViewBuilder
    private var applicationSection: some View {
        Section("Application") {
            NavigationLink(destination: AppearanceSettingsView()) {
                SettingsRow(title: "Appearance", systemImage: "paintbrush.fill", color: .pink)
            }
        }
        Section {
            Button(role: .destructive) {
                showClearCacheConfirm = true
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
        .confirmationDialog(
            "Clear Cache?",
            isPresented: $showClearCacheConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear Cache", role: .destructive) {
                Task {
                    await ImageCache.shared.clear()
                    await ResponseCache.shared.invalidateAll()
                    await refreshCacheSize()
                    showCacheCleared = true
                }
            }
        } message: {
            Text(cacheSizeBytes > 0
                 ? "This will remove \(Int64(cacheSizeBytes).byteString) of cached images and API data. Everything will be re-fetched as needed."
                 : "This will clear all cached images and API data.")
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        Section("About") {
            Link(destination: URL(string: "https://getarcane.app")!) {
                SettingsExternalRow(title: "Documentation", systemImage: "globe", color: .blue)
            }
            ShareLink(item: URL(string: "https://getarcane.app")!) {
                SettingsRow(title: "Share Arcane", systemImage: "square.and.arrow.up", color: .blue, titleColor: .primary)
            }
            Link(destination: URL(string: "https://discord.gg/WyXYpdyV3Z")!) {
                SettingsExternalRow(title: "Join the Discord", systemImage: "bubble.left.and.bubble.right.fill", color: .indigo)
            }
            Link(destination: URL(string: "https://github.com/getarcaneapp/ios")!) {
                SettingsExternalRow(title: "Contribute on GitHub", systemImage: "chevron.left.forwardslash.chevron.right", color: .purple)
            }
            Link(destination: URL(string: "https://github.com/getarcaneapp/ios/issues")!) {
                SettingsExternalRow(title: "Report an Issue", systemImage: "exclamationmark.bubble", color: .orange)
            }
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
        async let images = ImageCache.shared.currentBytes()
        async let responses = ResponseCache.shared.diskBytes()
        cacheSizeBytes = await images + responses
    }
}
