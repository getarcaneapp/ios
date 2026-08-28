import SwiftUI

struct ContentView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.scenePhase) private var scenePhase
    @SwiftUI.Environment(\.isLaunchSplashPresented) private var isLaunchSplashPresented
    @State private var showActivityCenter = false
    @State private var quickActionRouter = QuickActionRouter.shared

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
                if isLaunchSplashPresented {
                    authenticatedContent
                } else {
                    authenticatedContent
                        .arcaneWhatsNewSheet()
                }
            }
        }
        .task {
            await manager.checkExistingAuth()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await manager.retryConnectionBootstrapIfNeeded() }
        }
        .onChange(of: quickActionRouter.pendingActivityCenter, initial: true) { _, pending in
            guard pending, manager.supportsActivities else { return }
            quickActionRouter.pendingActivityCenter = false
            showActivityCenter = true
        }
        .sheet(isPresented: $showActivityCenter) {
            NavigationStack {
                ActivitiesView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                showActivityCenter = false
                            }
                        }
                    }
            }
            .toastHost(reservesTabBarSpace: false)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        // Deployment activity host: the floating progress pill and the stream
        // sheet for the active deploy/redeploy/pull operation. Mounted before
        // the toast host so toasts layer above the pill.
        .deploymentActivityHost()
        // Listen for new v2 activity updates even when Activity Center is not
        // open. The user's App Settings preference controls which starts become
        // app-wide toasts.
        .activityToastMonitor()
        // Single app-wide host for transient toasts. Mounted on the outer Group
        // so toasts layer above view-local confirmation overlays and also work
        // on the login / setup screens.
        .toastHost()
    }

    private var authenticatedContent: some View {
        VStack(spacing: 0) {
            DemoBanner()
            MainTabView()
        }
    }
}
