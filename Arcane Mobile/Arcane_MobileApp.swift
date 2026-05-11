import SwiftUI
import UIKit
import TipKit

@main
struct Arcane_MobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @SwiftUI.Environment(\.scenePhase) private var scenePhase
    @State private var clientManager = ArcaneClientManager()
    @State private var pinnedStore = PinnedItemsStore.shared
    @State private var resourceMutationStore = ResourceMutationStore.shared
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
                .tint(accentColorHex.isEmpty ? nil : accentColor)
                .task {
                    await ImageCache.shared.trimDiskCache()
                    try? Tips.configure([.displayFrequency(.immediate), .datastoreLocation(.applicationDefault)])
                }
                .onOpenURL { url in
                    if url.scheme == "arcane-mobile", url.host == "end-demo" {
                        Task { await clientManager.endDemo(reason: .userInitiated) }
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task { @MainActor in
                            ReviewPrompter.shared.maybePromptIfDue()
                        }
                    }
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
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
