import SwiftUI
import Arcane

struct SettingsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var volumeSizeBytes: Int64? = nil
    @State private var loadingVolumeSize = false
    @State private var navPath = NavigationPath()
    var excludedTabs: Set<AppTab> = []
    var showsSidebarButton = false
    var onOpenSidebar: () -> Void = {}
    var onNavigationRootChange: (Bool) -> Void = { _ in }

    var body: some View {
        // Manager access-catalog reads happen exactly once per body evaluation.
        // They must stay inside body (not init or stored props) so @Observable
        // access tracking re-fires on currentUser / serverCapabilities changes.
        let availableTabs = Set(
            AppTab.allCases.filter(manager.canAccess)
        )
        NavigationStack(path: $navPath) {
            List {
                Section {
                    NavigationLink {
                        ProfileView()
                    } label: {
                        UserAccountLabel()
                    }
                    .accessibilityHint("Opens profile")
                }

                SettingsTabSection(
                    title: "Management",
                    tabs: Self.visibleTabs(
                        .management,
                        excludedTabs: excludedTabs,
                        availableTabs: availableTabs
                    ),
                    availableTabs: availableTabs,
                    navPath: $navPath
                )
                SettingsResourcesSection(
                    tabs: Self.visibleTabs(
                        .resources,
                        excludedTabs: excludedTabs,
                        availableTabs: availableTabs
                    ),
                    availableTabs: availableTabs,
                    volumeSizeBytes: volumeSizeBytes,
                    loadingVolumeSize: loadingVolumeSize,
                    navPath: $navPath
                )
                SettingsTabSection(
                    title: "Swarm",
                    tabs: Self.visibleTabs(
                        .swarm,
                        excludedTabs: excludedTabs,
                        availableTabs: availableTabs
                    ),
                    availableTabs: availableTabs,
                    navPath: $navPath
                )
                SettingsTabSection(
                    title: "Administration",
                    tabs: Self.visibleTabs(
                        .administration,
                        excludedTabs: excludedTabs,
                        availableTabs: availableTabs
                    ),
                    availableTabs: availableTabs,
                    navPath: $navPath
                )
                SettingsTabSection(
                    title: "Settings",
                    tabs: AppTab.settings.children.filter(availableTabs.contains),
                    availableTabs: availableTabs,
                    navPath: $navPath
                )
            }
            .listStyle(.insetGrouped)
            // Push tab destinations by value so the whole Settings stack is
            // path-consistent. Object-based pushes here desynced the stack when
            // the pushed resource view (e.g. VolumesView) did its own value-based
            // child navigation — the detail landed under the re-rendered list.
            .navigationDestination(for: AppTab.self) { tab in
                appTabDestination(tab, manager: manager, selectedTab: .constant(""))
            }
            // Drop the morphing-bar controls the instant we pop back out of a
            // resource detail reached *via Settings*. The tab stacks get this from
            // `TabNavigationContainer`'s path watcher; the Settings stack needs its
            // own, otherwise the controls linger until the detail's (zoom-delayed)
            // `onDisappear`. Settings-pushed details register under the "settings" id.
            .onChange(of: navPath.count) { oldCount, newCount in
                if newCount < oldCount {
                    TabBarMorphStore.shared.clearTab("settings")
                }
            }
            .navigationTitle("Settings")
            .sidebarNavigationToolbar(isVisible: showsSidebarButton && navPath.isEmpty, action: onOpenSidebar)
            .preservesSidebarNavigationBarMargins(isEnabled: showsSidebarButton)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        AppSettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("App Settings")
                }
            }
            .task {
                await loadVolumeSize()
            }
            .onChange(of: navPath.isEmpty, initial: true) { _, isRoot in
                onNavigationRootChange(isRoot)
            }
        }
    }

    private static func visibleTabs(
        _ section: AppTab.Section,
        excludedTabs: Set<AppTab>,
        availableTabs: Set<AppTab>
    ) -> [AppTab] {
        AppTab.allCases.filter { tab in
            tab.section == section
                && tab.showsInNavigationMenus
                && tab != .settings
                && availableTabs.contains(tab)
        }.flatMap { tab in
            if excludedTabs.contains(tab) {
                return tab.children.filter(availableTabs.contains)
            }
            return [tab]
        }
    }

    private func loadVolumeSize() async {
        guard manager.canAccess(.volumes),
              let client = manager.client, let cached = manager.cached,
              volumeSizeBytes == nil, !loadingVolumeSize else { return }
        loadingVolumeSize = true
        defer { loadingVolumeSize = false }
        do {
            let path = client.rest.environmentPath(manager.activeEnvironmentID, "volumes/sizes")
            if let sizes: [VolumeSizeInfo] = try await cached.get(
                path, as: [VolumeSizeInfo].self, policy: .volumes,
                envID: manager.activeEnvironmentID,
                onFresh: { fresh in
                    volumeSizeBytes = fresh.reduce(Int64(0)) { $0 + $1.size }
                }
            ) {
                volumeSizeBytes = sizes.reduce(Int64(0)) { $0 + $1.size }
            }
        } catch {
            // Slow / unsupported on some hosts — leave blank silently.
        }
    }
}

// MARK: - Sections

/// Plain settings section: title + tab rows.
struct SettingsTabSection: View {
    let title: String
    let tabs: [AppTab]
    let availableTabs: Set<AppTab>
    @Binding var navPath: NavigationPath

    var body: some View {
        if !tabs.isEmpty {
            Section(title) {
                ForEach(tabs) { tab in
                    SettingsCatalogRow(
                        tab: tab,
                        availableTabs: availableTabs,
                        navPath: $navPath
                    )
                }
            }
        }
    }
}

/// Resources section: tab rows plus the volumes size badge.
struct SettingsResourcesSection: View {
    let tabs: [AppTab]
    let availableTabs: Set<AppTab>
    let volumeSizeBytes: Int64?
    let loadingVolumeSize: Bool
    @Binding var navPath: NavigationPath

    var body: some View {
        if !tabs.isEmpty {
            Section("Resources") {
                ForEach(tabs) { tab in
                    SettingsCatalogRow(
                        tab: tab,
                        availableTabs: availableTabs,
                        navPath: $navPath,
                        trailingValue: tab == .volumes ? volumeTrailingValue : nil,
                        showsProgress: tab == .volumes && loadingVolumeSize && volumeSizeBytes == nil
                    )
                }
            }
        }
    }

    private var volumeTrailingValue: String? {
        volumeSizeBytes?.byteString
    }
}

/// One shared-catalog row. Parent navigation and child disclosure use separate
/// buttons so expanding a catalog never consumes the destination tap.
private struct SettingsCatalogRow: View {
    let tab: AppTab
    let availableTabs: Set<AppTab>
    @Binding var navPath: NavigationPath
    var trailingValue: String?
    var showsProgress = false
    @State private var isExpanded = false

    private var children: [AppTab] {
        tab.children.filter(availableTabs.contains)
    }

    var body: some View {
        if children.isEmpty {
            destinationButton(tab, trailingValue: trailingValue, showsProgress: showsProgress)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    destinationButton(tab, trailingValue: trailingValue, showsProgress: showsProgress)

                    Button {
                        withAnimation(Motion.state) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 38)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Collapse \(tab.title)" : "Expand \(tab.title)")
                }

                if isExpanded {
                    ForEach(children) { child in
                        destinationButton(child)
                            .padding(.leading, 32)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
    }

    private func destinationButton(
        _ destination: AppTab,
        trailingValue: String? = nil,
        showsProgress: Bool = false
    ) -> some View {
        Button {
            navPath.append(destination)
        } label: {
            HStack {
                SettingsRow(
                    title: destination.title,
                    systemImage: destination.systemImage,
                    color: destination.iconColor
                )
                Spacer()
                if let trailingValue {
                    Text(trailingValue)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if showsProgress {
                    ProgressView().scaleEffect(0.7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens \(destination.title)")
    }
}
