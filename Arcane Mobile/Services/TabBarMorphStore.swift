import SwiftUI

// MARK: - Current tab id (environment)

private struct CurrentTabIDKey: EnvironmentKey {
    static let defaultValue: String = ""
}

extension EnvironmentValues {
    /// The id of the `AppTab` whose `NavigationStack` a view is rendered inside.
    /// `MainTabView` stamps this onto each tab's content so a pushed detail page
    /// can tell `TabBarMorphStore` which tab it belongs to. The store uses it to
    /// gate the morph to the *active* tab, so a detail left open in a background
    /// tab doesn't keep the bar morphed once you switch away.
    var currentTabID: String {
        get { self[CurrentTabIDKey.self] }
        set { self[CurrentTabIDKey.self] = newValue }
    }
}

// MARK: - Morph store

/// Single source of truth for the morphing tab bar's detail-page state.
///
/// Detail views publish their action set via `.morphingActions(...)`; the bar —
/// mounted once in `MainTabView` — renders whatever is active for the selected
/// tab and animates between the tabs pill and those controls. The trigger is
/// view lifecycle (appear/disappear) rather than a `NavigationPath`, because each
/// tab owns an independent stack.
@Observable
final class TabBarMorphStore {
    static let shared = TabBarMorphStore()
    private init() {}

    /// A detail page's controls, sourced from the same `ActionButtonItem` arrays
    /// the detail views already build for `.actionToolbar`.
    struct Payload {
        var primary: ActionButtonItem?
        var inline: [ActionButtonItem] = []
        var overflow: [ActionButtonItem] = []
        var runningItemID: String?
        var isDisabled: Bool = false
        var resourceName: String?
    }

    private struct Registration: Identifiable {
        let id: UUID
        let tabID: String
        var payload: Payload
        /// Root-page accessory actions: rendered as pills BESIDE the tabs
        /// capsule (bar stays un-morphed), unlike detail payloads which morph
        /// the bar into controls.
        var isRoot: Bool = false
    }

    /// The tab currently on screen. The active payload is the most-recent
    /// registration belonging to this tab.
    var activeTabID: String = ""

    /// Destructive item awaiting confirmation. Hosted as one shared dialog by the
    /// bar, mirroring `ActionToolbarModifier`'s behaviour.
    var pendingDestructive: ActionButtonItem?

    /// Re-tapping the already-selected tab pops its stack to root — the native
    /// tab bar behavior the custom bar replaces. `TabNavigationContainer`
    /// observes the token (so repeat requests for the same tab still fire) and
    /// clears its path when the tab matches.
    private(set) var popToRootTabID: String?
    private(set) var popToRootToken = 0

    func requestPopToRoot(tabID: String) {
        popToRootTabID = tabID
        popToRootToken &+= 1
    }

    private var registrations: [Registration] = []

    /// The controls to display for the active tab, or `nil` when on a list page.
    var activePayload: Payload? {
        registrations.last(where: { $0.tabID == activeTabID && !$0.isRoot })?.payload
    }

    var isMorphed: Bool { activePayload != nil }

    /// Accessory actions for the active tab's ROOT page, shown as pills next
    /// to the tabs capsule. Suppressed while a detail payload has the bar
    /// morphed.
    var activeRootActions: [ActionButtonItem] {
        guard activePayload == nil else { return [] }
        return registrations.last(where: { $0.tabID == activeTabID && $0.isRoot })?.payload.inline ?? []
    }

    /// Idempotent: registers a token, or replaces it if already present. Called
    /// both on appear and whenever the payload changes.
    func register(id: UUID, tabID: String, payload: Payload, isRoot: Bool = false) {
        if let idx = registrations.firstIndex(where: { $0.id == id }) {
            registrations[idx] = Registration(id: id, tabID: tabID, payload: payload, isRoot: isRoot)
        } else {
            registrations.append(Registration(id: id, tabID: tabID, payload: payload, isRoot: isRoot))
        }
    }

    func unregister(id: UUID) {
        registrations.removeAll { $0.id == id }
    }

    /// Drop every registration for a tab — used to un-morph immediately when a
    /// tab's navigation returns to its root, rather than waiting on the detail
    /// page's (late) `onDisappear`.
    func clearTab(_ tabID: String) {
        registrations.removeAll { $0.tabID == tabID }
    }
}

// MARK: - .morphingActions modifier

extension View {
    /// Publishes a detail page's controls to the morphing tab bar. Renders
    /// nothing itself — the bar mounted in `MainTabView` draws the controls and
    /// animates the morph. A drop-in alternative to `.actionToolbar` for pushed
    /// detail pages.
    ///
    /// - `primary`:  the emphasised, state-aware action shown as the centre capsule.
    /// - `inline`:   secondary actions shown as circular pills beside it.
    /// - `overflow`: the rest, tucked behind a "…" menu pill.
    ///
    /// Destructive items (`role: .destructive`) route through a shared
    /// confirmation dialog; items that need a bespoke dialog should use
    /// `role: nil` and trigger their own state from `action`.
    func morphingActions(
        primary: ActionButtonItem? = nil,
        inline: [ActionButtonItem] = [],
        overflow: [ActionButtonItem] = [],
        runningItemID: String? = nil,
        isDisabled: Bool = false,
        resourceName: String? = nil,
        active: Bool = true
    ) -> some View {
        modifier(MorphingActionsModifier(payload: TabBarMorphStore.Payload(
            primary: primary,
            inline: inline,
            overflow: overflow,
            runningItemID: runningItemID,
            isDisabled: isDisabled,
            resourceName: resourceName
        ), active: active))
    }
}

extension View {
    /// Publishes a ROOT page's accessory actions to the floating bar: rendered
    /// as circular pills beside the tabs capsule (the bar does not morph — the
    /// tabs stay usable). For pushed detail pages use `.morphingActions`.
    func rootBarActions(_ items: [ActionButtonItem]) -> some View {
        modifier(RootBarActionsModifier(items: items))
    }
}

private struct RootBarActionsModifier: ViewModifier {
    let items: [ActionButtonItem]
    @SwiftUI.Environment(\.currentTabID) private var tabID
    @State private var token = UUID()

    private var signature: String {
        items.map(\.id).joined(separator: "|") + "#\(tabID)"
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                TabBarMorphStore.shared.register(
                    id: token, tabID: tabID,
                    payload: .init(inline: items), isRoot: true
                )
            }
            .onChange(of: signature) {
                TabBarMorphStore.shared.register(
                    id: token, tabID: tabID,
                    payload: .init(inline: items), isRoot: true
                )
            }
            .onDisappear {
                TabBarMorphStore.shared.unregister(id: token)
            }
    }
}

private struct MorphingActionsModifier: ViewModifier {
    let payload: TabBarMorphStore.Payload
    let active: Bool
    @SwiftUI.Environment(\.currentTabID) private var tabID
    @State private var token = UUID()

    /// Cheap key that changes exactly when the rendered controls should: action
    /// identity, the running spinner, the disabled state, or the owning tab.
    /// `ActionButtonItem` isn't `Equatable` (it holds closures), so we can't
    /// observe the arrays directly.
    private var signature: String {
        let ids = (([payload.primary?.id].compactMap { $0 })
                   + payload.inline.map(\.id)
                   + payload.overflow.map(\.id)).joined(separator: "|")
        return "\(ids)#\(payload.runningItemID ?? "")#\(payload.isDisabled)#\(payload.resourceName ?? "")#\(active)#\(tabID)"
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                updateRegistration()
            }
            .onChange(of: signature) {
                updateRegistration()
            }
            .onDisappear {
                TabBarMorphStore.shared.unregister(id: token)
            }
    }

    private func updateRegistration() {
        if active {
            TabBarMorphStore.shared.register(id: token, tabID: tabID, payload: payload)
        } else {
            TabBarMorphStore.shared.unregister(id: token)
        }
    }
}
