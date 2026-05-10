import SwiftUI

struct ContentView: View {
    @Environment(ArcaneClientManager.self) private var manager

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
            }
        }
        .task {
            await manager.checkExistingAuth()
        }
    }
}
