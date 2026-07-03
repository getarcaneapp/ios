import SwiftUI
import Arcane

struct SettingsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var volumeSizeBytes: Int64? = nil
    @State private var loadingVolumeSize = false
    @State private var navPath = NavigationPath()

    var body: some View {
        // Manager / NavTabsStore reads happen exactly once per body evaluation.
        // They must stay inside body (not init or stored props) so @Observable
        // access tracking re-fires on currentUser / serverCapabilities /
        // pinned-tab changes. The sections below are Equatable value views, so
        // SwiftUI skips their bodies whenever these inputs are unchanged.
        let isAdmin = manager.currentUser?.isAdmin == true
        let supportsV2 = manager.serverCapabilities?.mode == .rbac
        let pinned = Set(NavTabsStore.shared.pinnedTabs)  // getter reads `version` for tracking

        NavigationStack(path: $navPath) {
            List {
                Section {
                    NavigationLink {
                        ProfileView()
                    } label: {
                        accountRow
                    }
                    .accessibilityLabel("Account")
                }

                SettingsTabSection(
                    title: "Management",
                    tabs: Self.visibleTabs(.management, pinned: pinned, isAdmin: isAdmin, supportsV2: supportsV2)
                )
                SettingsResourcesSection(
                    tabs: Self.visibleTabs(.resources, pinned: pinned, isAdmin: isAdmin, supportsV2: supportsV2),
                    volumeSizeBytes: volumeSizeBytes,
                    loadingVolumeSize: loadingVolumeSize
                )
                SettingsTabSection(
                    title: "Swarm",
                    tabs: Self.visibleTabs(.swarm, pinned: pinned, isAdmin: isAdmin, supportsV2: supportsV2)
                )
                SettingsTabSection(
                    title: "Administration",
                    tabs: Self.visibleTabs(.administration, pinned: pinned, isAdmin: isAdmin, supportsV2: supportsV2)
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
            .aiAssistantToolbar()
        }
    }

    /// Web-parity account row: initials avatar + name, pushes ProfileView.
    private var accountRow: some View {
        let name = manager.currentUser?.displayName?.isEmpty == false
            ? manager.currentUser?.displayName
            : manager.currentUser?.username
        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.gradient)
                    .frame(width: 36, height: 36)
                Text(String((name ?? "?").prefix(1)).uppercased())
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(name ?? "Account")
                    .font(.subheadline.weight(.medium))
                Text("Profile, email & password")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func visibleTabs(
        _ section: AppTab.Section,
        pinned: Set<AppTab>,
        isAdmin: Bool,
        supportsV2: Bool
    ) -> [AppTab] {
        AppTab.allCases.filter { tab in
            tab.section == section
                && !pinned.contains(tab)
                && (isAdmin || !tab.requiresAdmin)
                && (supportsV2 || !tab.requiresV2)
        }
    }

    private func loadVolumeSize() async {
        guard let client = manager.client, let cached = manager.cached,
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

    var body: some View {
        if !tabs.isEmpty {
            Section(title) {
                ForEach(tabs) { tab in
                    NavigationLink(value: tab) {
                        SettingsRow(
                            title: tab.title,
                            systemImage: tab.systemImage,
                            color: tab.iconColor
                        )
                    }
                }
            }
        }
    }
}

/// Resources section: tab rows plus the volumes size badge.
struct SettingsResourcesSection: View, Equatable {
    let tabs: [AppTab]
    let volumeSizeBytes: Int64?
    let loadingVolumeSize: Bool

    var body: some View {
        if !tabs.isEmpty {
            Section("Resources") {
                ForEach(tabs) { tab in
                    NavigationLink(value: tab) {
                        resourceRow(tab)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func resourceRow(_ tab: AppTab) -> some View {
        if tab == .volumes {
            HStack {
                SettingsRow(title: tab.title, systemImage: tab.systemImage, color: tab.iconColor)
                Spacer()
                if let size = volumeSizeBytes {
                    Text(size.byteString)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if loadingVolumeSize {
                    ProgressView().scaleEffect(0.7)
                }
            }
        } else {
            SettingsRow(title: tab.title, systemImage: tab.systemImage, color: tab.iconColor)
        }
    }
}
