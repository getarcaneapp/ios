import SwiftUI

struct ContentView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @AppStorage("arcane.lastSeenReleaseVersion") private var lastSeenVersion: String = ""
    @State private var showWhatsNew = false

    var body: some View {
        Group {
            switch manager.authState {
            case .setup:
                LoginView(mode: .setup)
            case .authenticating:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .login:
                LoginView(mode: .login)
            case .authenticated:
                VStack(spacing: 0) {
                    DemoBanner()
                    MainTabView()
                }
                .onAppear(perform: evaluateWhatsNew)
                .sheet(isPresented: $showWhatsNew) {
                    if let latest = ReleaseNotes.latest {
                        WhatsNewView(note: latest)
                            .onDisappear { lastSeenVersion = latest.version }
                    }
                }
            }
        }
        .task {
            await manager.checkExistingAuth()
        }
    }

    private func evaluateWhatsNew() {
        guard let latest = ReleaseNotes.latest else { return }
        if lastSeenVersion.isEmpty {
            // First launch — silently mark current version as seen; users get
            // release notes only on upgrade, not on initial install.
            lastSeenVersion = latest.version
            return
        }
        if lastSeenVersion != latest.version {
            showWhatsNew = true
        }
    }
}
