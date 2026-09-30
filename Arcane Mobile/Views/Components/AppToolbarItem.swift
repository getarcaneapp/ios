import SwiftUI

/// Applies the app accent inside the toolbar's hosted content, including
/// navigation stacks presented in sheets. Explicit label colors take precedence.
struct AppToolbarItem<Content: View>: ToolbarContent {
    private let id: String?
    private let placement: ToolbarItemPlacement
    private let content: Content

    init(
        id: String? = nil,
        placement: ToolbarItemPlacement = .automatic,
        @ViewBuilder content: () -> Content
    ) {
        self.id = id
        self.placement = placement
        self.content = content()
    }

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        if let id {
            ToolbarItem(id: id, placement: placement) {
                content.appAccentToolbarSymbol()
            }
        } else {
            ToolbarItem(placement: placement) {
                content.appAccentToolbarSymbol()
            }
        }
    }
}
