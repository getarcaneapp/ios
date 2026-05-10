import SwiftUI

@main
struct Arcane_MobileApp: App {
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
                }
        }
    }
}
