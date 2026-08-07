import SwiftUI

extension View {
    func sidebarNavigationToolbar(
        isVisible: Bool,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        toolbar {
            if isEnabled, isVisible {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: action) {
                        Image(systemName: "line.3.horizontal")
                    }
                    .accessibilityLabel("Open navigation")
                }

                if #available(iOS 26, *) {
                    ToolbarSpacer(.fixed, placement: .topBarLeading)
                }
            }
        }
    }
}
