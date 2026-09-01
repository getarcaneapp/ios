import CoreGraphics
import Testing

@testable import Arcane_Mobile

@Suite("Bottom bar scroll behavior")
struct BottomBarScrollBehaviorTests {
    @Test
    func downwardTravelCompactsAfterHysteresisThreshold() {
        var behavior = BottomBarScrollBehavior()

        #expect(behavior.update(with: sample(offset: 0)) == nil)
        #expect(behavior.update(with: sample(offset: 18)) == nil)
        #expect(behavior.update(with: sample(offset: 25)) == true)
        #expect(behavior.isCompact)
    }

    @Test
    func upwardTravelExpandsMoreQuickly() {
        var behavior = BottomBarScrollBehavior()

        _ = behavior.update(with: sample(offset: 0))
        _ = behavior.update(with: sample(offset: 30))
        #expect(behavior.isCompact)

        #expect(behavior.update(with: sample(offset: 23)) == nil)
        #expect(behavior.update(with: sample(offset: 17)) == false)
        #expect(!behavior.isCompact)
    }

    @Test
    func directionChangesResetAccumulatedTravel() {
        var behavior = BottomBarScrollBehavior()

        _ = behavior.update(with: sample(offset: 0))
        #expect(behavior.update(with: sample(offset: 14)) == nil)
        #expect(behavior.update(with: sample(offset: 10)) == nil)
        #expect(behavior.update(with: sample(offset: 23)) == nil)
        #expect(!behavior.isCompact)
        #expect(behavior.update(with: sample(offset: 35)) == true)
    }

    @Test
    func bottomEdgeBounceStaysCompactUntilActualUpwardScrolling() {
        var behavior = BottomBarScrollBehavior()

        _ = behavior.update(with: sample(offset: 0))
        _ = behavior.update(with: sample(offset: 100))
        #expect(behavior.isCompact)

        // Pulling beyond the bottom and bouncing back to its resting offset
        // is not user-directed upward scrolling.
        #expect(behavior.update(with: sample(offset: 126)) == nil)
        #expect(behavior.update(with: sample(offset: 100)) == nil)
        #expect(behavior.isCompact)

        // Moving away from the bottom still expands after the upward threshold.
        #expect(behavior.update(with: sample(offset: 93)) == nil)
        #expect(behavior.update(with: sample(offset: 87)) == false)
        #expect(!behavior.isCompact)
    }

    @Test
    func topEdgeAndNonScrollableContentStayExpanded() {
        var behavior = BottomBarScrollBehavior()

        _ = behavior.update(with: sample(offset: 0))
        _ = behavior.update(with: sample(offset: 30))
        #expect(behavior.isCompact)
        #expect(behavior.update(with: sample(offset: 6)) == false)

        _ = behavior.update(with: sample(offset: 40))
        _ = behavior.update(with: sample(offset: 70))
        #expect(behavior.isCompact)
        #expect(
            behavior.update(
                with: BottomBarScrollSample(
                    verticalOffset: 70,
                    maximumVerticalOffset: 0,
                    isVerticallyScrollable: false
                )
            ) == false
        )
    }

    private func sample(
        offset: CGFloat,
        maximumOffset: CGFloat = 100
    ) -> BottomBarScrollSample {
        BottomBarScrollSample(
            verticalOffset: offset,
            maximumVerticalOffset: maximumOffset,
            isVerticallyScrollable: true
        )
    }
}
