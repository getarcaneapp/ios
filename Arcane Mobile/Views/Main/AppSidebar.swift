import SwiftUI
import Arcane

nonisolated enum SidebarUtilityDestination: String {
    case profile
    case appSettings = "app-settings"
}

/// Top-level navigation used by the optional sidebar mode.
///
/// The sidebar intentionally shares `AppTab` metadata with the dock and
/// Settings so titles, symbols, permissions, and backend capability gates stay
/// consistent across every navigation surface.
struct AppSidebar: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(FleetStore.self) private var fleet
    @SwiftUI.Environment(ActivityHistoryMutationStore.self) private var historyMutationStore
    @ScaledMetric(relativeTo: .largeTitle) private var logoHeight: CGFloat = 34
    @ScaledMetric(relativeTo: .largeTitle) private var logoLineHeight: CGFloat = 41

    private struct SidebarGroupData: Identifiable {
        let id: AppTab.Section
        let title: String
        let tabs: [AppTab]
    }

    let selectedID: String
    let accentColor: Color
    let onSelect: (String) -> Void
    @State private var expandedTabs: Set<AppTab> = [.images, .networks, .customize, .settings]
    @State private var activityStore = ActivityCenterStore()
    @State private var showUpgrade = false

    private let groups: [SidebarGroupData]
    private let availableTabs: Set<AppTab>

    init(
        tabs: [AppTab],
        selectedID: String,
        accentColor: Color,
        onSelect: @escaping (String) -> Void
    ) {
        self.selectedID = selectedID
        self.accentColor = accentColor
        self.onSelect = onSelect
        let available = Set(tabs)
        availableTabs = available
        groups = AppTab.Section.allCases.compactMap { section in
            let roots = AppTab.allCases.filter {
                $0.section == section && $0.showsInNavigationMenus && available.contains($0)
            }
            guard !roots.isEmpty else { return nil }
            return SidebarGroupData(id: section, title: section.title, tabs: roots)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image("ArcaneSidebarLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: logoHeight, alignment: .leading)
                    .accessibilityLabel("Arcane")

                SidebarActivityButton(failureCount: failedActivityCount)
            }
            .frame(height: logoLineHeight)
            .padding(.leading, 20)
            .padding(.trailing, 14)
            .padding(.top, 18)
            .padding(.bottom, 16)

            environmentSwitcher
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            if showsUpgradeBanner {
                Button {
                    showUpgrade = true
                } label: {
                    Label("Arcane update available", systemImage: "arrow.up.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.orange.opacity(0.12), in: .rect(cornerRadius: Radius.standard))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(groups) { group in
                        SidebarGroup(
                            title: group.title,
                            tabs: group.tabs,
                            selectedID: selectedID,
                            accentColor: accentColor,
                            availableTabs: availableTabs,
                            expandedTabs: $expandedTabs,
                            onSelect: onSelect
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 88)
            }
            .scrollIndicators(.hidden)
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 8) {
                SidebarProfileButton(
                    isSelected: selectedID == SidebarUtilityDestination.profile.rawValue,
                    accentColor: accentColor
                ) {
                    onSelect(SidebarUtilityDestination.profile.rawValue)
                }

                Spacer(minLength: 0)

                SidebarSettingsButton(
                    isSelected: selectedID == SidebarUtilityDestination.appSettings.rawValue,
                    accentColor: accentColor
                ) {
                    onSelect(SidebarUtilityDestination.appSettings.rawValue)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .background(Color(uiColor: .systemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation")
        .task(id: manager.client.map { ObjectIdentifier($0.transport) }) {
            await fleet.load(manager: manager)
            fleet.setVisible(true, consumer: "sidebar", supportsDashboardStream: manager.supportsActivities)
            guard manager.supportsActivities else { return }
            activityStore.configure(client: manager.client)
            await activityStore.load()
            activityStore.startStream()
        }
        .onDisappear {
            activityStore.stopStream()
            fleet.setVisible(false, consumer: "sidebar", supportsDashboardStream: manager.supportsActivities)
        }
        .onChange(of: historyMutationStore.latestClear) { _, event in
            guard let event else { return }
            activityStore.removeClearedHistory(environmentIDs: event.environmentIDs)
            Task { await activityStore.load(refresh: true) }
        }
        .sheet(isPresented: $showUpgrade) {
            NavigationStack { SystemUpgradeView(environmentID: manager.activeEnvironmentID) }
        }
    }

    private var environmentSwitcher: some View {
        Menu {
            ForEach(fleet.environments) { environment in
                Button {
                    manager.setActiveEnvironment(
                        id: EnvironmentID(rawValue: environment.id),
                        name: environment.name ?? environment.id
                    )
                } label: {
                    if environment.id == manager.activeEnvironmentID.rawValue {
                        Label(environment.name ?? environment.id, systemImage: "checkmark")
                    } else {
                        Text(environment.name ?? environment.id)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "server.rack")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Environment")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(manager.activeEnvironmentName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: Radius.standard))
        }
        .buttonStyle(.plain)
        .disabled(fleet.environments.isEmpty)
        .accessibilityLabel("Active environment: \(manager.activeEnvironmentName)")
    }

    private var failedActivityCount: Int {
        activityStore.historyItems.reduce(0) { total, item in
            switch item {
            case .activity(let activity): return total + (activity.status == .failed ? 1 : 0)
            case .batch(let batch): return total + batch.failedCount
            }
        }
    }

    private var showsUpgradeBanner: Bool {
        guard manager.permissions.has(Permission.System.upgrade),
              let state = fleet.dashboardStream.state(for: manager.activeEnvironmentID.rawValue),
              state.hasLoaded else { return false }
        return state.snapshot?.versionInfo?.updateAvailable == true
    }
}

private struct SidebarActivityButton: View {
    @State private var router = QuickActionRouter.shared
    let failureCount: Int

    var body: some View {
        Button {
            router.openActivityCenter()
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title2.weight(.semibold))
                .overlay(alignment: .topTrailing) {
                    if failureCount > 0 {
                        Text(failureCount > 99 ? "99+" : String(failureCount))
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(.red, in: .capsule)
                            .offset(x: 9, y: -8)
                    }
                }
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .contentShape(.circle)
        .accessibilityLabel(failureCount > 0 ? "Activity Center, \(failureCount) failures" : "Activity Center")
    }
}

private struct SidebarSettingsButton: View {
    let isSelected: Bool
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape.fill")
                .font(.title.weight(.semibold))
                .foregroundStyle(isSelected ? accentColor : .primary)
        }
        .buttonStyle(.plain)
        .frame(width: 52, height: 52)
        .contentShape(.circle)
        .glassEffectCompat(interactive: true, in: .circle)
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
            UserAvatarCircle(size: 52, font: .title3.bold())
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(accentColor, lineWidth: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .frame(width: 52, height: 52)
        .contentShape(.circle)
        .accessibilityLabel("Profile")
        .accessibilityHint("Opens profile")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SidebarGroup: View {
    let title: String
    let tabs: [AppTab]
    let selectedID: String
    let accentColor: Color
    let availableTabs: Set<AppTab>
    @Binding var expandedTabs: Set<AppTab>
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)

            ForEach(tabs) { tab in
                let children = tab.children.filter(availableTabs.contains)
                VStack(spacing: 4) {
                    SidebarDestinationButton(
                        title: tab.title,
                        systemImage: tab.systemImage,
                        isSelected: selectedID == tab.id,
                        accentColor: accentColor,
                        disclosureExpanded: children.isEmpty ? nil : expandedTabs.contains(tab),
                        disclosureAction: children.isEmpty ? nil : {
                            withAnimation(Motion.state) {
                                if expandedTabs.contains(tab) {
                                    expandedTabs.remove(tab)
                                } else {
                                    expandedTabs.insert(tab)
                                }
                            }
                        }
                    ) {
                        onSelect(tab.id)
                    }

                    if expandedTabs.contains(tab) {
                        ForEach(children) { child in
                            SidebarDestinationButton(
                                title: child.title,
                                systemImage: child.systemImage,
                                isSelected: selectedID == child.id,
                                accentColor: accentColor,
                                isChild: true
                            ) {
                                onSelect(child.id)
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
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
    var isChild = false
    var disclosureExpanded: Bool?
    var disclosureAction: (() -> Void)?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 0) {
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
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(.rect)
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if let disclosureExpanded {
                Button(action: { disclosureAction?() }) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(disclosureExpanded ? 90 : 0))
                        .frame(width: 38, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(disclosureExpanded ? "Collapse \(title)" : "Expand \(title)")
            }
        }
        .padding(.leading, isChild ? 32 : 10)
        .padding(.trailing, disclosureExpanded == nil ? 10 : 2)
        .background(isSelected ? accentColor.opacity(0.12) : .clear)
        .clipShape(.rect(cornerRadius: Radius.standard))
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

    private let edgeGestureWidth: CGFloat = 12

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
                    .simultaneousGesture(closeDrawerGesture(width: drawerWidth))
                    .accessibilityLabel("Close navigation")
                } else if isNavigationRoot {
                    // Keep the open gesture on the physical screen edge. A
                    // drag recognizer on this entire container competes with
                    // every button, row, and switch after only a few points of
                    // finger movement.
                    Color.clear
                        .frame(width: edgeGestureWidth)
                        .frame(maxHeight: .infinity)
                        .contentShape(.rect)
                        .gesture(openDrawerGesture(width: drawerWidth))
                        .accessibilityHidden(true)
                }
            }
            // Expand the drawer layer rather than its GeometryReader. The
            // destination receives the physical screen with no top/bottom
            // spacer while `proxy.safeAreaInsets` remains available above for
            // the independently inset sidebar.
            .ignoresSafeArea(.container)
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

    private func openDrawerGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                lockDragIntent(for: value)
                guard dragIntent == .horizontal,
                      value.translation.width > 0 else { return }
                dragTranslation = min(value.translation.width, width)
            }
            .onEnded { value in
                let isHorizontal = dragIntent == .horizontal
                dragIntent = nil
                let shouldOpen = isHorizontal
                    && value.translation.width > 32
                    && value.predictedEndTranslation.width > width * 0.35
                settleSidebar(presented: shouldOpen)
            }
    }

    private func closeDrawerGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                lockDragIntent(for: value)
                guard dragIntent == .horizontal,
                      value.translation.width < 0 else { return }
                dragTranslation = max(value.translation.width, -width)
            }
            .onEnded { value in
                let isHorizontal = dragIntent == .horizontal
                dragIntent = nil
                let projectedTranslation = min(
                    value.translation.width,
                    value.predictedEndTranslation.width
                )
                let shouldClose = isHorizontal && projectedTranslation < -24
                settleSidebar(presented: !shouldClose)
            }
    }

    private func lockDragIntent(for value: DragGesture.Value) {
        guard dragIntent == nil else { return }
        let horizontal = abs(value.translation.width)
        let vertical = abs(value.translation.height)
        guard max(horizontal, vertical) >= 12 else { return }
        dragIntent = horizontal > vertical * 1.35 ? .horizontal : .vertical
    }

    private func settleSidebar(presented: Bool) {
        withAnimation(Motion.reduced(Motion.overlay, reduceMotion: reduceMotion)) {
            isPresented = presented
            dragTranslation = 0
        }
    }
}
