import SwiftUI
import TipKit

/// One-time popover teaching users that long-pressing a tab opens the swap
/// sheet. Auto-dismisses forever once the user discovers the gesture organically.
struct TabSwapTip: Tip {
    @Parameter static var didDiscoverFeature: Bool = false

    var title: Text {
        Text("Customize your tab bar")
    }

    var message: Text? {
        Text("Long-press any tab to swap it with a destination from Settings.")
    }

    var image: Image? {
        Image(systemName: "rectangle.bottomthird.inset.filled")
    }

    var rules: [Rule] {
        [#Rule(Self.$didDiscoverFeature) { $0 == false }]
    }
}
