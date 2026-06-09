import SwiftUI
import Arcane

/// Injects the AI assistant sparkle button into the navigation bar leading
/// area for every screen in a `NavigationStack`. Gated on iOS 26+, a live
/// server connection, and the `arcane.showAssistantButton` preference.
struct AIAssistantToolbarModifier: ViewModifier {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @AppStorage("arcane.showAssistantButton") private var showAssistantButton = true
    @State private var showAssistant = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                if #available(iOS 26, *) {
                    if showAssistantButton, manager.client != nil {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { showAssistant = true } label: {
                                Image(systemName: "sparkles")
                            }
                            .accessibilityLabel("AI Assistant")
                        }
                        ToolbarSpacer(.fixed, placement: .topBarLeading)
                    }
                }
            }
            .sheet(isPresented: $showAssistant) {
                if #available(iOS 26, *) {
                    NavigationStack {
                        AIAssistantView()
                    }
                }
            }
    }
}

extension View {
    func aiAssistantToolbar() -> some View {
        modifier(AIAssistantToolbarModifier())
    }
}
