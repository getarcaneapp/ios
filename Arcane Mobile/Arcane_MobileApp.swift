import SwiftUI
import UIKit
import TipKit
import Arcane

@main
struct Arcane_MobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @SwiftUI.Environment(\.scenePhase) private var scenePhase
    @State private var clientManager = ArcaneClientManager()
    private var pinnedStore = PinnedItemsStore.shared
    private var resourceMutationStore = ResourceMutationStore.shared
    private var imageUpdateCountStore = ImageUpdateCountStore.shared
    @AppStorage("accentColorHex") private var accentColorHex = ""

    private var accentColor: Color {
        guard !accentColorHex.isEmpty, let color = Color(hex: accentColorHex) else {
            return .accentColor
        }
        return color
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(clientManager)
                .environment(pinnedStore)
                .environment(resourceMutationStore)
                .environment(imageUpdateCountStore)
                .tint(accentColorHex.isEmpty ? nil : accentColor)
                .task {
                    Task.detached(priority: .background) { ImageCache.shared.trimDiskCache() }
                    try? Tips.configure([.displayFrequency(.immediate), .datastoreLocation(.applicationDefault)])
                    // Live Activities left behind by an app kill can never
                    // update again — clear them on launch.
                    await DeployLiveActivityController.endOrphans()
                }
                .onOpenURL { url in
                    if url.scheme == "arcane-mobile", url.host == "end-demo" {
                        Task { await clientManager.endDemo(reason: .userInitiated) }
                        return
                    }
                    if QuickActionRouter.shared.handle(url: url) {
                        // Widget deep links can carry a target environment —
                        // switch the active context before the tab shows.
                        if let envID = QuickActionRouter.shared.pendingDeepLink?.environmentID,
                           envID != clientManager.activeEnvironmentID.rawValue {
                            clientManager.setActiveEnvironment(
                                id: EnvironmentID(rawValue: envID),
                                name: envID
                            )
                        }
                    }
                }
                .onChange(of: accentColorHex) { _, newValue in
                    AppGroup.defaults?.set(newValue, forKey: AppGroup.Keys.accentColorHex)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task { @MainActor in
                            ReviewPrompter.shared.maybePromptIfDue()
                        }
                    }
                    if newPhase == .background {
                        // Land any queued widget snapshot before suspension.
                        WidgetSnapshotPublisher.shared.flush()
                    }
                    // Buys a running deployment stream the background grace
                    // period so its Live Activity can finish cleanly.
                    DeploymentActivityStore.shared.handleScenePhase(newPhase)
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        configureLegacyBarAppearance()
        publishVersionToSettingsBundle()
        return true
    }

    /// The Settings.bundle "Version"/"Build" rows are PSTitleValueSpecifiers that
    /// display UserDefaults values, so they must be refreshed on every launch to
    /// track the installed build.
    private func publishVersionToSettingsBundle() {
        let info = Bundle.main.infoDictionary
        let defaults = UserDefaults.standard
        defaults.set(info?["CFBundleShortVersionString"] as? String ?? "—",
                     forKey: "arcane.settings.appVersion")
        defaults.set(info?["CFBundleVersion"] as? String ?? "—",
                     forKey: "arcane.settings.appBuild")
    }

    /// On iOS 18 the traditional tab bar flips between its transparent scroll-edge
    /// appearance and its opaque standard appearance as a tab's content loads
    /// under it, which reads as a flash when switching tabs. Pin both to the same
    /// default (blurred) background so there's no flip. iOS 26 uses Liquid Glass
    /// bars and manages this itself, so skip it there.
    ///
    /// We intentionally do NOT pin the navigation bar: several screens (e.g. the
    /// Dashboard) use an empty inline title with a custom in-content header and
    /// rely on the nav bar staying transparent at the top, so forcing an opaque
    /// background there would butt the header against a visible bar.
    private func configureLegacyBarAppearance() {
        guard #unavailable(iOS 26) else { return }

        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let shortcut = options.shortcutItem {
            _ = QuickActionRouter.shared.handle(shortcut)
        }
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let handled = QuickActionRouter.shared.handle(shortcutItem)
        completionHandler(handled)
    }
}
