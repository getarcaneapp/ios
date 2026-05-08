import SwiftUI

@main
struct Arcane_MobileApp: App {
    @State private var clientManager = ArcaneClientManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(clientManager)
        }
    }
}
