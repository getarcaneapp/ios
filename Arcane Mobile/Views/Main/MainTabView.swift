import SwiftUI
import UIKit
import TipKit
import Arcane

struct MainTabView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var selectedTab: String = AppTab.dashboard.id
    @State private var swapTarget: AppTab? = nil
    @State private var store = NavTabsStore.shared
    @State private var router = QuickActionRouter.shared
    @AppStorage("arcane.tip.tabSwapDismissed") private var tabSwapTipDismissed = false

    private var isAdmin: Bool { manager.currentUser?.isAdmin == true }

    private var visibleTabs: [AppTab] {
        store.visibleTabs(isAdmin: isAdmin)
    }

    @ViewBuilder
    private var coreTabView: some View {
        TabView(selection: $selectedTab) {
            ForEach(visibleTabs) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab.id) {
                    NavigationStack {
                        appTabDestination(tab, manager: manager, selectedTab: $selectedTab)
                    }
                    .id(tab.isEnvironmentScoped ? "\(tab.id)-\(manager.activeEnvironmentID.rawValue)" : tab.id)
                }
            }
            Tab("Settings", systemImage: "gearshape.fill", value: "settings") {
                SettingsView()
            }
        }
    }

    var body: some View {
        Group {
            if tabSwapTipDismissed {
                coreTabView
            } else {
                // The accessory modifier reserves a slot above the floating tab
                // bar. Apply it only while the tip is undismissed so the slot
                // disappears entirely once the user dismisses or long-presses.
                coreTabView
                    .tabViewBottomAccessory {
                        TabSwapHintBanner {
                            tabSwapTipDismissed = true
                            TabSwapTip.didDiscoverFeature = true
                        }
                    }
            }
        }
        .background {
            TabBarLongPressInstaller { idx in
                let tabs = visibleTabs
                guard idx >= 0, idx < tabs.count else { return }
                HapticsManager.medium()
                tabSwapTipDismissed = true
                TabSwapTip.didDiscoverFeature = true
                swapTarget = tabs[idx]
            }
        }
        .sheet(item: $swapTarget) { current in
            TabSwapSheet(current: current) { replacement in
                HapticsManager.success()
                store.swap(pinned: current, with: replacement)
                if selectedTab == current.id { selectedTab = replacement.id }
                swapTarget = nil
            }
            .environment(manager)
        }
        .onChange(of: router.pendingTabID) { _, newValue in
            guard let target = newValue else { return }
            selectedTab = target
            router.pendingTabID = nil
        }
        .onAppear {
            if let target = router.pendingTabID {
                selectedTab = target
                router.pendingTabID = nil
            }
        }
    }
}

// MARK: - Hint banner

/// Compact one-liner sized to fit the `tabViewBottomAccessory` slot. Shows
/// once and stays dismissed forever once tapped X or the user long-presses a
/// tab (which sets the same `@AppStorage` key).
private struct TabSwapHintBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.tap.fill")
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            Text("Long-press a tab to customize")
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
                    .imageScale(.medium)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss hint")
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hint: long-press a tab to customize the tab bar")
    }
}

// MARK: - Long-press detection

/// Attaches a `UILongPressGestureRecognizer` to the underlying `UITabBar`
/// once it's available in the window hierarchy. Uses `cancelsTouchesInView =
/// false` so normal tab taps continue to work. Only fires for the first 4 tab
/// slots — the rightmost (Settings) slot is treated as a no-op.
private struct TabBarLongPressInstaller: UIViewRepresentable {
    let onLongPress: (Int) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onLongPress = onLongPress
        if !context.coordinator.installed {
            DispatchQueue.main.async {
                tryInstall(from: uiView, coordinator: context.coordinator, retries: 10)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onLongPress: onLongPress)
    }

    private func tryInstall(from anchor: UIView, coordinator: Coordinator, retries: Int) {
        guard !coordinator.installed else { return }
        if let window = anchor.window, let tabBar = findTabBar(in: window) {
            let lp = UILongPressGestureRecognizer(
                target: coordinator,
                action: #selector(Coordinator.handle(_:))
            )
            lp.minimumPressDuration = 0.4
            lp.cancelsTouchesInView = false
            lp.delegate = coordinator
            tabBar.addGestureRecognizer(lp)
            coordinator.installed = true
            coordinator.tabBar = tabBar
            return
        }
        guard retries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak anchor] in
            guard let anchor else { return }
            tryInstall(from: anchor, coordinator: coordinator, retries: retries - 1)
        }
    }

    private func findTabBar(in view: UIView) -> UITabBar? {
        if let tb = view as? UITabBar { return tb }
        for sub in view.subviews {
            if let tb = findTabBar(in: sub) { return tb }
        }
        return nil
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onLongPress: (Int) -> Void
        weak var tabBar: UITabBar?
        var installed = false

        init(onLongPress: @escaping (Int) -> Void) {
            self.onLongPress = onLongPress
        }

        @objc func handle(_ gr: UILongPressGestureRecognizer) {
            guard gr.state == .began, let tabBar else { return }
            let loc = gr.location(in: tabBar)
            let slots = max(tabBar.items?.count ?? 5, 1)
            guard tabBar.bounds.width > 0 else { return }
            let slotWidth = tabBar.bounds.width / CGFloat(slots)
            let idx = min(max(Int(loc.x / slotWidth), 0), slots - 1)
            // The rightmost slot is Settings — locked, no swap.
            if idx >= slots - 1 { return }
            onLongPress(idx)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
