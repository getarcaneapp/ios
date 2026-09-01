import CoreGraphics
import Observation

/// The small slice of scroll geometry needed to drive the floating tab bar.
/// Keeping this value Equatable lets `onScrollGeometryChange` discard updates
/// that do not affect the behavior.
nonisolated struct BottomBarScrollSample: Equatable, Sendable {
    let verticalOffset: CGFloat
    let maximumVerticalOffset: CGFloat
    let isVerticallyScrollable: Bool
}

/// Direction-aware hysteresis for the floating tab bar. Downward scrolling
/// must travel farther than upward scrolling so the bar gets out of the way
/// deliberately but returns quickly when the user changes direction.
nonisolated struct BottomBarScrollBehavior {
    private enum Direction: Equatable {
        case down
        case up
    }

    private static let topExpansionOffset: CGFloat = 8
    private static let minimumCollapseOffset: CGFloat = 20
    private static let collapseTravel: CGFloat = 24
    private static let expansionTravel: CGFloat = 12
    private static let minimumDelta: CGFloat = 0.5

    private(set) var isCompact = false
    private var previousOffset: CGFloat?
    private var direction: Direction?
    private var directionalTravel: CGFloat = 0

    /// Returns a new compact state only when the visual state should change.
    mutating func update(with sample: BottomBarScrollSample) -> Bool? {
        // Rubber-band scrolling can temporarily report offsets beyond the real
        // bottom. Clamp to the valid range so the rebound is not mistaken for
        // user-directed upward scrolling.
        let maximumOffset = max(0, sample.maximumVerticalOffset)
        let offset = min(max(0, sample.verticalOffset), maximumOffset)

        guard sample.isVerticallyScrollable else {
            resetTracking(at: offset)
            return setCompact(false)
        }

        if offset <= Self.topExpansionOffset {
            resetTracking(at: offset)
            return setCompact(false)
        }

        guard let previousOffset else {
            self.previousOffset = offset
            return nil
        }

        let delta = offset - previousOffset
        self.previousOffset = offset
        guard abs(delta) >= Self.minimumDelta else { return nil }

        let newDirection: Direction = delta > 0 ? .down : .up
        if newDirection == direction {
            directionalTravel += abs(delta)
        } else {
            direction = newDirection
            directionalTravel = abs(delta)
        }

        switch newDirection {
        case .down:
            guard !isCompact,
                  offset >= Self.minimumCollapseOffset,
                  directionalTravel >= Self.collapseTravel else { return nil }
            directionalTravel = 0
            return setCompact(true)

        case .up:
            guard isCompact,
                  directionalTravel >= Self.expansionTravel else { return nil }
            directionalTravel = 0
            return setCompact(false)
        }
    }

    mutating func reset() {
        isCompact = false
        previousOffset = nil
        direction = nil
        directionalTravel = 0
    }

    private mutating func resetTracking(at offset: CGFloat) {
        previousOffset = offset
        direction = nil
        directionalTravel = 0
    }

    private mutating func setCompact(_ compact: Bool) -> Bool? {
        guard isCompact != compact else { return nil }
        isCompact = compact
        return compact
    }
}

/// Observable facade for SwiftUI. Per-frame tracking stays observation-ignored;
/// only an actual expanded/compact transition invalidates the tab-bar view.
@MainActor
@Observable
final class BottomBarScrollStore {
    private(set) var isCompact = false

    @ObservationIgnored private var behavior = BottomBarScrollBehavior()

    func observe(_ sample: BottomBarScrollSample) {
        guard let compact = behavior.update(with: sample) else { return }
        isCompact = compact
    }

    func reset() {
        behavior.reset()
        guard isCompact else { return }
        isCompact = false
    }
}
