import SwiftUI
import Arcane

struct SettingsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var volumeSizeBytes: Int64? = nil
    @State private var loadingVolumeSize = false
    @State private var navPath = NavigationPath()
    var showsSidebarButton = false
    var onOpenSidebar: () -> Void = {}
    var onNavigationRootChange: (Bool) -> Void = { _ in }

    var body: some View {
        // Manager access-catalog reads happen exactly once per body evaluation.
        // They must stay inside body (not init or stored props) so @Observable
        // access tracking re-fires on currentUser / serverCapabilities changes.
        // The sections below are Equatable value views, so
        // SwiftUI skips their bodies whenever these inputs are unchanged.
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
                    tabs: Self.visibleTabs(.management, availableTabs: availableTabs),
                    availableTabs: availableTabs
                )
                SettingsResourcesSection(
                    tabs: Self.visibleTabs(.resources, availableTabs: availableTabs),
                    availableTabs: availableTabs,
                    volumeSizeBytes: volumeSizeBytes,
                    loadingVolumeSize: loadingVolumeSize
                )
                SettingsTabSection(
                    title: "Swarm",
                    tabs: Self.visibleTabs(.swarm, availableTabs: availableTabs),
                    availableTabs: availableTabs
                )
                SettingsTabSection(
                    title: "Administration",
                    tabs: Self.visibleTabs(.administration, availableTabs: availableTabs),
                    availableTabs: availableTabs
                )
                SettingsTabSection(
                    title: "Settings",
                    tabs: AppTab.settings.children.filter(availableTabs.contains),
                    availableTabs: availableTabs
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
        availableTabs: Set<AppTab>
    ) -> [AppTab] {
        AppTab.allCases.filter { tab in
            tab.section == section
                && tab.showsInNavigationMenus
                && tab != .settings
                && availableTabs.contains(tab)
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

// These section views must stay Equatable-only value types: plain stored
// properties, no @Environment, no closures. That's what lets SwiftUI compare
// them with == and skip their bodies when the inputs haven't changed.

/// Plain settings section: title + tab rows.
struct SettingsTabSection: View, Equatable {
    let title: String
    let tabs: [AppTab]
    let availableTabs: Set<AppTab>

    var body: some View {
        if !tabs.isEmpty {
            Section(title) {
                ForEach(tabs) { tab in
                    SettingsCatalogRow(tab: tab, availableTabs: availableTabs)
                }
            }
        }
    }
}

/// Resources section: tab rows plus the volumes size badge.
struct SettingsResourcesSection: View, Equatable {
    let tabs: [AppTab]
    let availableTabs: Set<AppTab>
    let volumeSizeBytes: Int64?
    let loadingVolumeSize: Bool

    var body: some View {
        if !tabs.isEmpty {
            Section("Resources") {
                ForEach(tabs) { tab in
                    SettingsCatalogRow(
                        tab: tab,
                        availableTabs: availableTabs,
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

/// One shared-catalog row. Parents remain selectable while the system
/// disclosure control reveals their authorized child destinations.
private struct SettingsCatalogRow: View, Equatable {
    let tab: AppTab
    let availableTabs: Set<AppTab>
    var trailingValue: String?
    var showsProgress = false

    private var children: [AppTab] {
        tab.children.filter(availableTabs.contains)
    }

    var body: some View {
        if children.isEmpty {
            destinationLink(tab, trailingValue: trailingValue, showsProgress: showsProgress)
        } else {
            DisclosureGroup {
                ForEach(children) { child in
                    destinationLink(child)
                        .padding(.leading, 8)
                }
            } label: {
                destinationLink(tab, trailingValue: trailingValue, showsProgress: showsProgress)
            }
        }
    }

    private func destinationLink(
        _ destination: AppTab,
        trailingValue: String? = nil,
        showsProgress: Bool = false
    ) -> some View {
        NavigationLink(value: destination) {
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
        }
    }
}
