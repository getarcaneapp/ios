import SwiftUI

nonisolated enum SidebarUtilityDestination: String {
    case profile
    case settings
}

/// Top-level navigation used by the optional sidebar mode.
///
/// The sidebar intentionally shares `AppTab` metadata with the dock and
/// Settings so titles, symbols, permissions, and backend capability gates stay
/// consistent across every navigation surface.
struct AppSidebar: View {
    private struct SidebarGroupData: Identifiable {
        let id: AppTab.Section
        let title: String
        let tabs: [AppTab]
    }

    let selectedID: String
    let accentColor: Color
    let onSelect: (String) -> Void

    private let groups: [SidebarGroupData]

    init(
        tabs: [AppTab],
        selectedID: String,
        accentColor: Color,
        onSelect: @escaping (String) -> Void
    ) {
        self.selectedID = selectedID
        self.accentColor = accentColor
        self.onSelect = onSelect
        groups = [
            SidebarGroupData(id: .management, title: "Management", tabs: tabs.filter { $0.section == .management }),
            SidebarGroupData(id: .resources, title: "Resources", tabs: tabs.filter { $0.section == .resources }),
            SidebarGroupData(id: .swarm, title: "Swarm", tabs: tabs.filter { $0.section == .swarm }),
            SidebarGroupData(
                id: .administration,
                title: "Administration",
                tabs: tabs.filter { $0.section == .administration }
            )
        ].filter { !$0.tabs.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Arcane")
                .font(.largeTitle.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 16)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(groups) { group in
                        SidebarGroup(
                            title: group.title,
                            tabs: group.tabs,
                            selectedID: selectedID,
                            accentColor: accentColor,
                            onSelect: onSelect
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)

            Divider()

            HStack(spacing: 8) {
                SidebarProfileButton(
                    isSelected: selectedID == SidebarUtilityDestination.profile.rawValue,
                    accentColor: accentColor
                ) {
                    onSelect(SidebarUtilityDestination.profile.rawValue)
                }

                SidebarSettingsButton(
                    isSelected: selectedID == SidebarUtilityDestination.settings.rawValue,
                    accentColor: accentColor
                ) {
                    onSelect(SidebarUtilityDestination.settings.rawValue)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation")
    }
}

private struct SidebarSettingsButton: View {
    let isSelected: Bool
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(isSelected ? accentColor : .primary)
                .frame(width: 20, height: 20)
        }
        .buttonBorderShape(.circle)
        .controlSize(.regular)
        .glassButtonStyleCompat()
        .accessibilityLabel("App Settings")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SidebarProfileButton: View {
    let isSelected: Bool
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            UserAccountLabel(avatarSize: 42)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .padding(.horizontal, 10)
                .background(isSelected ? accentColor.opacity(0.12) : .clear)
                .clipShape(.rect(cornerRadius: Radius.standard))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .layoutPriority(1)
        .accessibilityHint("Opens profile")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SidebarGroup: View {
    let title: String
    let tabs: [AppTab]
    let selectedID: String
    let accentColor: Color
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)

            ForEach(tabs) { tab in
                SidebarDestinationButton(
                    title: tab.title,
                    systemImage: tab.systemImage,
                    isSelected: selectedID == tab.id,
                    accentColor: accentColor
                ) {
                    onSelect(tab.id)
                }
            }
        }
    }
}

private struct SidebarDestinationButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
                    .font(.body.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: systemImage)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isSelected ? accentColor : .primary)
                    .frame(width: 28)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 10)
            .background(isSelected ? accentColor.opacity(0.12) : .clear)
            .clipShape(.rect(cornerRadius: Radius.standard))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Chat-style compact drawer used when sidebar mode runs in a compact width.
/// Direct manipulation is driven by a narrow leading-edge gesture while closed
/// and a horizontal dismiss gesture while open, leaving the system back swipe
/// untouched on pushed destinations.
struct CompactSidebarDrawer<Sidebar: View, Content: View>: View {
    private enum DragIntent: Equatable {
        case horizontal
        case vertical
    }

    @Binding var isPresented: Bool
    let isNavigationRoot: Bool
    @ViewBuilder let sidebar: Sidebar
    @ViewBuilder let content: Content

    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragTranslation: CGFloat = 0
    @State private var dragIntent: DragIntent?

    var body: some View {
        GeometryReader { proxy in
            let drawerWidth = min(proxy.size.width * 0.82, 340)
            let progress = drawerProgress(width: drawerWidth)

            ZStack(alignment: .topLeading) {
                Color(uiColor: .systemBackground)

                sidebar
                    // The outer geometry remains safe-area aware, so these are
                    // the system's live status-bar and home-indicator insets.
                    // Apply them only to the sidebar, never the destination.
                    .padding(.top, proxy.safeAreaInsets.top)
                    .padding(.bottom, proxy.safeAreaInsets.bottom)
                    .frame(width: drawerWidth)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .offset(x: -drawerWidth * (1 - progress))

                content
                    // Keep the destination at its full compact width while the
                    // drawer translates the finished surface.
                    .frame(width: proxy.size.width, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    // Tint before transforming so the color remains inside the
                    // main-content card instead of painting the drawer's full
                    // untransformed layout bounds.
                    .overlay {
                        Color(uiColor: .secondarySystemBackground)
                            .opacity(0.55 * progress)
                            .allowsHitTesting(false)
                    }
                    .compositingGroup()
                    .clipShape(.rect(cornerRadius: Radius.hero))
                    .shadow(color: .black.opacity(0.18 * progress), radius: 20, x: -6, y: 0)
                    .offset(x: drawerWidth * progress)

                // The transformed content retains a full-screen layout frame,
                // so its old overlay could intercept every sidebar tap. Keep
                // dismissal strictly on the exposed trailing content instead.
                if isPresented {
                    Button(action: closeSidebar) {
                        Color.clear
                    }
                    .buttonStyle(.plain)
                    .frame(width: max(0, proxy.size.width - drawerWidth))
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
                    .offset(x: drawerWidth)
                    .accessibilityLabel("Close navigation")
                }
            }
            // Expand the drawer layer rather than its GeometryReader. The
            // destination receives the physical screen with no top/bottom
            // spacer while `proxy.safeAreaInsets` remains available above for
            // the independently inset sidebar.
            .ignoresSafeArea(.container)
            // Own the drag at the container level so it survives the clear
            // tap-dismiss button. `drawerGesture` limits closing to gestures
            // that begin on the exposed main-content card.
            .simultaneousGesture(drawerGesture(width: drawerWidth))
            .animation(Motion.reduced(Motion.overlay, reduceMotion: reduceMotion), value: isPresented)
            .onChange(of: isNavigationRoot) { _, isRoot in
                if !isRoot { settleSidebar(presented: false) }
            }
        }
    }

    private func drawerProgress(width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let base = isPresented ? width : 0
        return min(max((base + dragTranslation) / width, 0), 1)
    }

    private func closeSidebar() {
        settleSidebar(presented: false)
    }

    private func drawerGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if isPresented {
                    guard value.startLocation.x >= width else { return }
                    lockDragIntent(for: value)
                    guard dragIntent == .horizontal,
                          value.translation.width < 0 else { return }
                    dragTranslation = max(value.translation.width, -width)
                    return
                }

                guard isNavigationRoot,
                      value.startLocation.x <= 24 else { return }
                lockDragIntent(for: value)
                guard dragIntent == .horizontal,
                      value.translation.width > 0 else { return }
                dragTranslation = min(value.translation.width, width)
            }
            .onEnded { value in
                if isPresented {
                    guard value.startLocation.x >= width else {
                        resetDragState()
                        return
                    }
                    let isHorizontal = dragIntent == .horizontal
                    dragIntent = nil
                    let projectedTranslation = min(
                        value.translation.width,
                        value.predictedEndTranslation.width
                    )
                    let shouldClose = isHorizontal && projectedTranslation < -24
                    settleSidebar(presented: !shouldClose)
                    return
                }

                guard isNavigationRoot,
                      value.startLocation.x <= 24 else {
                    resetDragState()
                    return
                }
                let isHorizontal = dragIntent == .horizontal
                dragIntent = nil
                let shouldOpen = isHorizontal
                    && value.translation.width > 32
                    && value.predictedEndTranslation.width > width * 0.35
                settleSidebar(presented: shouldOpen)
            }
    }

    private func lockDragIntent(for value: DragGesture.Value) {
        guard dragIntent == nil else { return }
        let horizontal = abs(value.translation.width)
        let vertical = abs(value.translation.height)
        guard max(horizontal, vertical) >= 12 else { return }
        dragIntent = horizontal > vertical * 1.35 ? .horizontal : .vertical
    }

    private func resetDragState() {
        dragIntent = nil
        if dragTranslation != 0 {
            settleSidebar(presented: isPresented)
        }
    }

    private func settleSidebar(presented: Bool) {
        withAnimation(Motion.reduced(Motion.overlay, reduceMotion: reduceMotion)) {
            isPresented = presented
            dragTranslation = 0
        }
    }
}
