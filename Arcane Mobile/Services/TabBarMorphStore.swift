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
    }

    /// The tab currently on screen. The active payload is the most-recent
    /// registration belonging to this tab.
    var activeTabID: String = ""

    /// Destructive item awaiting confirmation. Hosted as one shared dialog by the
    /// bar, mirroring `ActionToolbarModifier`'s behaviour.
    var pendingDestructive: ActionButtonItem?

    private var registrations: [Registration] = []

    /// The controls to display for the active tab, or `nil` when on a list page.
    var activePayload: Payload? {
        registrations.last(where: { $0.tabID == activeTabID })?.payload
    }

    var isMorphed: Bool { activePayload != nil }

    /// Idempotent: registers a token, or replaces it if already present. Called
    /// both on appear and whenever the payload changes.
    func register(id: UUID, tabID: String, payload: Payload) {
        if let idx = registrations.firstIndex(where: { $0.id == id }) {
            registrations[idx] = Registration(id: id, tabID: tabID, payload: payload)
        } else {
            registrations.append(Registration(id: id, tabID: tabID, payload: payload))
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
        resourceName: String? = nil
    ) -> some View {
        modifier(MorphingActionsModifier(payload: TabBarMorphStore.Payload(
            primary: primary,
            inline: inline,
            overflow: overflow,
            runningItemID: runningItemID,
            isDisabled: isDisabled,
            resourceName: resourceName
        )))
    }
}

private struct MorphingActionsModifier: ViewModifier {
    let payload: TabBarMorphStore.Payload
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
        return "\(ids)#\(payload.runningItemID ?? "")#\(payload.isDisabled)#\(tabID)"
    }

    func body(content: Content) -> some View {
        content
            // Reserve the floating bar's footprint on the detail page itself so
            // its content clears the bar (applied to the page, not the stack —
            // a stack-level inset doesn't propagate into the List).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: MorphingTabBar.reservedHeight)
            }
            .onAppear {
                TabBarMorphStore.shared.register(id: token, tabID: tabID, payload: payload)
            }
            .onChange(of: signature) {
                TabBarMorphStore.shared.register(id: token, tabID: tabID, payload: payload)
            }
            .onDisappear {
                TabBarMorphStore.shared.unregister(id: token)
            }
    }
}
