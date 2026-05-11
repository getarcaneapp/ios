import SwiftUI
import Arcane

struct TabSwapSheet: View {
    let current: AppTab
    let onPick: (AppTab) -> Void

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss

    private var isAdmin: Bool { manager.currentUser?.isAdmin == true }
    private var store: NavTabsStore { .shared }

    private var pinnedSet: Set<AppTab> { Set(store.pinnedTabs) }

    private func eligible(_ section: AppTab.Section) -> [AppTab] {
        AppTab.allCases.filter { $0.section == section && !pinnedSet.contains($0) && $0 != current }
    }

    private var displacedMainTabs: [AppTab] {
        AppTab.mainDefaults.filter { $0.section == .main && !pinnedSet.contains($0) && $0 != current }
    }

    var body: some View {
        NavigationStack {
            List {
                if !displacedMainTabs.isEmpty {
                    Section("Overview") {
                        ForEach(displacedMainTabs) { pickRow($0) }
                    }
                }

                let resourcesEligible = eligible(.resources)
                if !resourcesEligible.isEmpty {
                    Section("Resources") {
                        ForEach(resourcesEligible) { pickRow($0) }
                    }
                }

                if isAdmin {
                    let adminEligible = eligible(.administration)
                    if !adminEligible.isEmpty {
                        Section("Administration") {
                            ForEach(adminEligible) { pickRow($0) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Replace \(current.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func pickRow(_ tab: AppTab) -> some View {
        Button {
            onPick(tab)
        } label: {
            SettingsRow(
                title: tab.title,
                systemImage: tab.systemImage,
                color: tab.iconColor,
                titleColor: .primary
            )
        }
        .buttonStyle(.plain)
    }
}
