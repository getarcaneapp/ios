import SwiftUI
import Arcane

struct TabSwapSheet: View {
    let current: AppTab
    let onPick: (AppTab) -> Void

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var showResetConfirm = false

    private var isAdmin: Bool { manager.currentUser?.isAdmin == true }
    private var store: NavTabsStore { .shared }

    private var pinnedSet: Set<AppTab> { Set(store.pinnedTabs) }

    private func eligible(_ section: AppTab.Section) -> [AppTab] {
        AppTab.allCases.filter { tab in
            tab.section == section
                && !pinnedSet.contains(tab)
                && tab != current
                && (isAdmin || !tab.requiresAdmin)
        }
    }

    private static let columnCount = 3

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    let management = eligible(.management)
                    if !management.isEmpty {
                        section(title: "Management", tabs: management)
                    }

                    let resources = eligible(.resources)
                    if !resources.isEmpty {
                        section(title: "Resources", tabs: resources)
                    }

                    let swarm = eligible(.swarm)
                    if !swarm.isEmpty {
                        section(title: "Swarm", tabs: swarm)
                    }

                    let administration = eligible(.administration)
                    if !administration.isEmpty {
                        section(title: "Administration", tabs: administration)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Replace \(current.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Reset", role: .destructive) {
                        showResetConfirm = true
                    }
                    .disabled(store.pinnedTabs == AppTab.mainDefaults)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .confirmationDialog(
            "Reset Tab Bar?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset to Default", role: .destructive) {
                store.resetToDefaults()
                dismiss()
            }
        } message: {
            Text("Restores the bottom tab bar to Dashboard, Containers, Images, and Projects.")
        }
    }

    @ViewBuilder
    private func section(title: String, tabs: [AppTab]) -> some View {
        let rows = Self.chunked(tabs, into: Self.columnCount)
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.leading, 4)
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(row) { tab in
                            TabTile(tab: tab, onPick: onPick)
                        }
                        if row.count < Self.columnCount {
                            ForEach(0..<(Self.columnCount - row.count), id: \.self) { _ in
                                Color.clear
                            }
                        }
                    }
                }
            }
        }
    }

    private static func chunked(_ tabs: [AppTab], into size: Int) -> [[AppTab]] {
        stride(from: 0, to: tabs.count, by: size).map {
            Array(tabs[$0..<min($0 + size, tabs.count)])
        }
    }
}

private struct TabTile: View {
    let tab: AppTab
    let onPick: (AppTab) -> Void

    var body: some View {
        Button {
            onPick(tab)
        } label: {
            VStack(spacing: 10) {
                Image(systemName: tab.systemImage)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(tab.iconColor)
                    .frame(width: 44, height: 44)
                    .background(tab.iconColor.opacity(0.15), in: .circle)
                Text(tab.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 8)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}
