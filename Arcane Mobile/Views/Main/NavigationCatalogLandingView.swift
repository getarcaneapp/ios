import SwiftUI

/// Selectable landing page for a navigation catalog parent.
struct NavigationCatalogLandingView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let parent: AppTab

    private var children: [AppTab] {
        parent.children.filter(manager.canAccess)
    }

    var body: some View {
        List {
            if children.isEmpty {
                ContentUnavailableView(
                    "No Available Sections",
                    systemImage: parent.systemImage,
                    description: Text("Your account does not have access to any sections here.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section(parent.title) {
                    ForEach(children) { child in
                        NavigationLink {
                            appTabDestination(child, manager: manager, selectedTab: .constant(parent.id))
                        } label: {
                            SettingsRow(
                                title: child.title,
                                systemImage: child.systemImage,
                                color: child.iconColor
                            )
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(parent.title)
    }
}
