import SwiftUI

struct ContentView: View {
    @Environment(ArcaneClientManager.self) private var manager
    @Environment(AppLockManager.self) private var lockManager
    @Environment(\.scenePhase) private var scenePhase

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
                MainTabView()
            }
        }
        .task {
            await manager.checkExistingAuth()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                lockManager.lockIfEnabled()
            } else if newPhase == .active, lockManager.isLocked {
                Task { await lockManager.authenticate() }
            }
        }
        .overlay {
            if lockManager.isLocked && manager.authState == .authenticated {
                AppLockView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: lockManager.isLocked)
    }
}
