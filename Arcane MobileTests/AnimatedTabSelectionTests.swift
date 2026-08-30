import Testing
import SwiftUI
import UIKit

@testable import Arcane_Mobile

@Suite("Animated tab selection")
struct AnimatedTabSelectionTests {
    private let tabs = [
        MorphingTabBar.TabEntry(
            id: "dashboard",
            title: "Dashboard",
            symbol: "chart.bar.fill",
            isReplaceable: true
        ),
        MorphingTabBar.TabEntry(
            id: "containers",
            title: "Containers",
            symbol: "cube.box.fill",
            isReplaceable: true
        ),
        MorphingTabBar.TabEntry(
            id: "settings",
            title: "Settings",
            symbol: "gearshape.fill",
            isReplaceable: false
        ),
    ]

    @Test
    func selectedIDMapsToVisualIndex() {
        #expect(TabStripSelection.index(selectedID: "containers", in: tabs) == 1)
        #expect(TabStripSelection.index(selectedID: "missing", in: tabs) == 0)
    }

    @Test
    func tapSelectsANewTabAndReselectsTheCurrentTab() {
        #expect(
            TabStripSelection.action(for: 1, selectedID: "dashboard", in: tabs)
                == .select("containers")
        )
        #expect(
            TabStripSelection.action(for: 0, selectedID: "dashboard", in: tabs)
                == .reselect("dashboard")
        )
        #expect(
            TabStripSelection.action(for: 8, selectedID: "dashboard", in: tabs)
                == .ignore
        )
    }

    @Test
    func selectionFollowsReorderedAndReducedTabSets() {
        let reordered = [tabs[1], tabs[0], tabs[2]]
        let reduced = [tabs[0], tabs[2]]

        #expect(TabStripSelection.index(selectedID: "dashboard", in: reordered) == 1)
        #expect(TabStripSelection.index(selectedID: "settings", in: reduced) == 1)
    }

    @Test
    func settingsIsNotReplaceable() {
        #expect(TabStripSelection.canReplace(index: 0, in: tabs))
        #expect(!TabStripSelection.canReplace(index: 2, in: tabs))
        #expect(!TabStripSelection.canReplace(index: 8, in: tabs))
    }

    @Test
    func indicatorUsesEqualWidthSlotsAndMirrorsForRightToLeftLayouts() {
        #expect(
            TabStripLayout.indicatorCenterX(
                index: 0,
                count: 5,
                width: 350,
                isRightToLeft: false
            ) == 35
        )
        #expect(
            TabStripLayout.indicatorCenterX(
                index: 0,
                count: 5,
                width: 350,
                isRightToLeft: true
            ) == 315
        )
        #expect(
            TabStripLayout.indicatorCenterX(
                index: 4,
                count: 5,
                width: 350,
                isRightToLeft: true
            ) == 35
        )
        #expect(
            TabStripLayout.indicatorCenterX(
                index: 5,
                count: 5,
                width: 350,
                isRightToLeft: false
            ) == nil
        )
    }

    @MainActor
    @Test
    func compactStripRendersWithACustomAccentAtTheExistingBarHeight() throws {
        let lightImage = try renderedStrip(colorScheme: .light)
        let darkImage = try renderedStrip(colorScheme: .dark)

        #expect(lightImage.size == CGSize(width: 390, height: 100))
        #expect(darkImage.size == CGSize(width: 390, height: 100))
        Attachment.record(lightImage, named: "animated-tab-strip-light", as: .png)
        Attachment.record(darkImage, named: "animated-tab-strip-dark", as: .png)
    }

    @MainActor
    private func renderedStrip(colorScheme: ColorScheme) throws -> UIImage {
        let visualTabs = [
            tabs[0],
            tabs[1],
            MorphingTabBar.TabEntry(
                id: "images",
                title: "Images",
                symbol: "photo.fill",
                isReplaceable: true
            ),
            MorphingTabBar.TabEntry(
                id: "volumes",
                title: "Volumes",
                symbol: "square.3.layers.3d",
                isReplaceable: true
            ),
            tabs[2],
        ]
        let fixture = AnimatedTabStripVisuals(
            tabs: visualTabs,
            selectedIndex: .constant(0),
            activeIndex: 0,
            accentColor: Color(hex: "#FF9500") ?? .orange
        )
        .frame(width: 350, height: 60)
        .clipShape(.capsule)
        .background(.ultraThinMaterial, in: .capsule)
        .padding(20)
        .background(Color(uiColor: .systemGroupedBackground))
        .environment(\.colorScheme, colorScheme)

        let renderer = ImageRenderer(content: fixture)
        renderer.scale = 3
        return try #require(renderer.uiImage)
    }
}
