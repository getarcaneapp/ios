import SwiftUI

@main
struct Arcane_MobileApp: App {
    @State private var clientManager = ArcaneClientManager()
    @State private var lockManager = AppLockManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(clientManager)
                .environment(lockManager)
        }
    }
}
