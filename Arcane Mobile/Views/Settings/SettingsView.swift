import SwiftUI

struct SettingsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager

    let visibleTabs: [AppTab]
    @Binding var selectedTab: String

    @State private var navPath: [AppTab] = []
    @State private var search = ""

    init(
        visibleTabs: [AppTab] = [],
        selectedTab: Binding<String> = .constant(AppTab.settings.id)
    ) {
        self.visibleTabs = visibleTabs
        _selectedTab = selectedTab
    }

    private var availableTabs: Set<AppTab> {
        Set(AppTab.allCases.filter(manager.canAccess))
    }

    private var visibleTabSet: Set<AppTab> {
        Set(visibleTabs)
    }

    private var groups: [MoreDestinationGroup] {
        [
            MoreDestinationGroup(
                title: "Management",
                tabs: [.dashboard, .updates, .projects]
            ),
            MoreDestinationGroup(
                title: "Resources",
                tabs: [
                    .containers, .images, .imageVulnerabilities, .networks,
                    .ports, .networkTopology, .volumes, .swarm
                ]
            ),
            MoreDestinationGroup(
                title: "Administration",
                tabs: [
                    .events, .activities, .customize, .templateRegistries,
                    .containerRegistries, .variables, .gitRepositories, .gitOps
                ]
            ),
            MoreDestinationGroup(
                title: "Server Settings",
                tabs: [
                    .apiKeys, .federatedCredentials, .systemBackups, .webhooks,
                    .authentication, .oidcRoleMappings, .notifications, .jobs,
                    .users, .roles, .systemSettings
                ]
            )
        ]
    }

    private var filteredGroups: [MoreDestinationGroup] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return groups.compactMap { group in
            let accessible = group.tabs.filter(availableTabs.contains)
            let matches = query.isEmpty
                ? accessible
                : accessible.filter {
                    $0.title.localizedCaseInsensitiveContains(query)
                        || group.title.localizedCaseInsensitiveContains(query)
                }
            return matches.isEmpty ? nil : MoreDestinationGroup(title: group.title, tabs: matches)
        }
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            List {
                accountSection
                destinationSections
            }
            .listStyle(.insetGrouped)
            .navigationTitle("More")
            .searchable(text: $search, prompt: "Search destinations")
            .overlay {
                if filteredGroups.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .navigationDestination(for: AppTab.self) { tab in
                appTabDestination(tab, manager: manager, selectedTab: $selectedTab)
            }
            .environmentContext(
                isVisible: navPath.last?.isEnvironmentScoped == true,
                onSelect: { navPath.removeAll() }
            )
        }
        .onChange(of: manager.activeEnvironmentID) { oldValue, newValue in
            if oldValue != newValue, navPath.contains(where: \.isEnvironmentScoped) {
                navPath.removeAll()
            }
        }
    }

    private var accountSection: some View {
        Section {
            NavigationLink {
                ProfileView()
            } label: {
                UserAccountLabel()
            }
            .accessibilityHint("Opens profile")

            NavigationLink {
                AppSettingsView()
            } label: {
                SettingsRow(
                    title: "App Settings",
                    systemImage: "gearshape.fill",
                    color: .gray
                )
            }

            NavigationLink {
                EditTabsView(availableTabs: availableTabs)
            } label: {
                SettingsRow(
                    title: "Edit Tabs",
                    systemImage: "rectangle.3.group.fill",
                    color: .indigo
                )
            }
        }
    }

    @ViewBuilder
    private var destinationSections: some View {
        ForEach(filteredGroups) { group in
            Section(group.title) {
                ForEach(group.tabs) { tab in
                    Button {
                        open(tab)
                    } label: {
                        HStack {
                            SettingsRow(
                                title: tab.title,
                                systemImage: tab.systemImage,
                                color: tab.iconColor
                            )
                            Spacer()
                            if visibleTabSet.contains(tab) {
                                Text("Tab")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Image(systemName: "arrow.turn.down.left")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(visibleTabSet.contains(tab)
                        ? "Switches to the \(tab.title) tab"
                        : "Opens \(tab.title)")
                }
            }
        }
    }

    private func open(_ tab: AppTab) {
        if visibleTabSet.contains(tab) {
            selectedTab = tab.id
        } else {
            navPath.append(tab)
        }
    }
}

private struct MoreDestinationGroup: Identifiable {
    let title: String
    let tabs: [AppTab]

    var id: String { title }
}

private struct EditTabsView: View {
    let availableTabs: Set<AppTab>

    @State private var store = NavTabsStore.shared
    @State private var selection: [AppTab]

    init(availableTabs: Set<AppTab>) {
        self.availableTabs = availableTabs
        let visible = NavTabsStore.shared.visibleTabs(availableTabs: availableTabs)
        _selection = State(initialValue: visible)
    }

    private var candidates: [AppTab] {
        AppTab.allCases.filter {
            $0.canPinToBottomBar && availableTabs.contains($0)
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(Array(selection.enumerated()), id: \.element.id) { index, tab in
                    Menu {
                        ForEach(replacements(for: tab)) { replacement in
                            Button {
                                replaceTab(at: index, with: replacement)
                            } label: {
                                Label(replacement.title, systemImage: replacement.systemImage)
                            }
                        }
                    } label: {
                        HStack {
                            SettingsRow(
                                title: tab.title,
                                systemImage: tab.systemImage,
                                color: tab.iconColor
                            )
                            Spacer()
                            Text("Tab \(index + 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                }
                .onMove(perform: moveTabs)
            } header: {
                Text("Tab Bar")
            } footer: {
                Text("Choose four unique destinations. More always stays in the fifth position.")
            }

            Section {
                Button("Reset to Defaults", systemImage: "arrow.counterclockwise") {
                    store.resetToDefaults()
                    selection = store.visibleTabs(availableTabs: availableTabs)
                }
            }
        }
        .navigationTitle("Edit Tabs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }

    private func replacements(for current: AppTab) -> [AppTab] {
        candidates.filter { $0 == current || !selection.contains($0) }
    }

    private func replaceTab(at index: Int, with replacement: AppTab) {
        guard selection.indices.contains(index) else { return }
        selection[index] = replacement
        save()
    }

    private func moveTabs(from source: IndexSet, to destination: Int) {
        selection.move(fromOffsets: source, toOffset: destination)
        save()
    }

    private func save() {
        guard selection.count == 4 else { return }
        _ = store.setPinnedTabs(selection)
    }
}
