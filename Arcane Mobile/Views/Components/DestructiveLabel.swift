import SwiftUI

/// Keeps both a destructive action's symbol and title red on neutral surfaces.
///
/// A destructive button role alone does not consistently override inherited
/// accent colors for SF Symbols in menus and context menus.
struct DestructiveLabel: View {
    let text: String
    var systemImage: String = "trash"

    var body: some View {
        Label {
            Text(text)
                .foregroundStyle(.red)
        } icon: {
            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.red)
        }
    }
}
