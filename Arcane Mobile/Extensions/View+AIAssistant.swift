import SwiftUI
import Arcane

/// Injects the AI assistant sparkle button into the navigation bar leading
/// area for every screen in a `NavigationStack`. Gated on iOS 26+, a live
/// server connection, and the `arcane.showAssistantButton` preference.
struct AIAssistantToolbarModifier: ViewModifier {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @AppStorage("arcane.showAssistantButton") private var showAssistantButton = true

    let isEnabled: Bool
    let showsNavigationButton: Bool
    let navigationAction: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .toolbar {
                if isEnabled, showsNavigationButton, let navigationAction {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: navigationAction) {
                            Image(systemName: "line.3.horizontal")
                        }
                        .accessibilityLabel("Open navigation")
                    }
                }

                if #available(iOS 26, *) {
                    if isEnabled, showAssistantButton, manager.client != nil {
                        if showsNavigationButton {
                            ToolbarSpacer(.fixed, placement: .topBarLeading)
                        }
                        ToolbarItem(placement: .topBarLeading) {
                            AIAssistantToolbarButton()
                        }
                        ToolbarSpacer(.fixed, placement: .topBarLeading)
                    }
                }
            }
    }
}

/// Reusable AI action for screens that already own their toolbar declaration.
struct AIAssistantToolbarButton: View {
    @State private var showAssistant = false

    var body: some View {
        if #available(iOS 26, *) {
            Button { showAssistant = true } label: {
                Image(systemName: "sparkles")
            }
            .accessibilityLabel("AI Assistant")
            .sheet(isPresented: $showAssistant) {
                NavigationStack {
                    AIAssistantView()
                }
            }
        }
    }
}

extension View {
    func aiAssistantToolbar() -> some View {
        modifier(
            AIAssistantToolbarModifier(
                isEnabled: true,
                showsNavigationButton: false,
                navigationAction: nil
            )
        )
    }

    /// Places sidebar navigation before the optional AI action in one toolbar
    /// declaration so SwiftUI cannot reorder independently composed modifiers.
    func sidebarNavigationToolbar(
        isVisible: Bool,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        modifier(
            AIAssistantToolbarModifier(
                isEnabled: isEnabled,
                showsNavigationButton: isVisible,
                navigationAction: action
            )
        )
    }
}
