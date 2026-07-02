import CoreGraphics

// MARK: - Radius tokens
//
// A single, restrained vocabulary for corner radii across card surfaces. Corner
// radii used to be hand-typed (10–24pt) and scattered across ~15 files; these
// named tokens are the one source of truth. Sibling to `Motion.swift`, which is
// scoped to motion only.
//
// The goal is a "pillowed" look echoing the iOS 27 icon language: generous
// continuous/squircle corners. For wide cards the height drives the pillow read
// — 22pt on a ~110pt-tall tile ≈ 20% (the icon-squircle ratio) without going
// pill.
//
// House rules — keep every touched shape honest:
//   • Every `RoundedRectangle(cornerRadius:)` must pass `style: .continuous`
//     (its default is `.circular`, visibly boxier at these radii). `.rect(...)`
//     is already continuous.
//   • Radii stay compile-time constants — never animated or state-driven. Glass
//     caches its shape and won't shrink, so a tier change mid-animation snaps.
enum Radius {
    /// Nested elements inside a card: mini metrics, inline banners, icon wells.
    static let nested: CGFloat = 12
    /// Grouped-list-style surfaces: info groups, small panels.
    static let standard: CGFloat = 16
    /// Primary cards, tiles, bubbles, the composer. The default tier.
    static let card: CGFloat = 22
    /// Hero surfaces: environment dashboard card, login panel.
    static let hero: CGFloat = 28

    /// Concentric inner radius for an element inset inside a rounded container.
    /// Keeps a rounded child visually parallel to its parent's corner instead of
    /// looking either too round or too square against it.
    static func concentric(outer: CGFloat, inset: CGFloat) -> CGFloat {
        max(outer - inset, 4)
    }
}
