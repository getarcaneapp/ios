import SwiftUI
import Arcane

/// Read-only details about the connected Arcane server (version, runtime,
/// build metadata). Rows copy their value on tap.
struct ServerInfoView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var serverVersion: ServerVersionInfo?
    @State private var isLoading = false

    var body: some View {
        List {
            if let v = serverVersion {
                Section {
                    serverRow("Version", value: clean(v.displayVersion) ?? clean(v.currentVersion),
                              icon: "shippingbox.fill", color: .blue)
                    if let tag = clean(v.currentTag) {
                        serverRow("Image Tag", value: tag, icon: "tag.fill", color: .purple)
                    }
                    if v.updateAvailable == true, let newest = clean(v.newestVersion) {
                        serverRow("Update Available", value: newest,
                                  icon: "arrow.up.circle.fill", color: .blue)
                    }
                } footer: {
                    Text("Tap a row to copy its value.")
                }
                Section("Runtime") {
                    if let node = clean(v.nodeVersion) {
                        serverRow("Node", value: node, icon: "leaf.fill", color: .green)
                    }
                    if let sk = clean(v.svelteKitVersion) {
                        serverRow("SvelteKit", value: sk, icon: "bolt.fill", color: .orange)
                    }
                    if let go = clean(v.goVersion) {
                        serverRow("Go", value: go, icon: "g.circle.fill", color: .teal)
                    }
                }
                Section("Build") {
                    if let rev = clean(v.shortRevision) {
                        serverRow("Revision", value: rev, copy: v.revision ?? rev,
                                  icon: "number", color: .gray, mono: true)
                    }
                    if let bt = clean(v.buildTime) {
                        serverRow("Build Time", value: bt, icon: "clock.fill", color: .gray)
                    }
                }
            } else if isLoading {
                HStack {
                    Text("Loading…").foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                }
            } else {
                ContentUnavailableView(
                    "Server Info Unavailable",
                    systemImage: "server.rack",
                    description: Text("Couldn't load version details from the server.")
                )
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Server Info")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
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

    private func load() async {
        guard let client = manager.client, serverVersion == nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await client.transport.rawRequest(
                "app-version", body: Optional<String>.none, authorized: false)
            serverVersion = try JSONDecoder().decode(ServerVersionInfo.self, from: data)
        } catch {
            // Leave nil — the unavailable state covers it.
        }
    }
}
