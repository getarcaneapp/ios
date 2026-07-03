import SwiftUI
import Arcane

struct UpdatesView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.currentTabID) private var currentTabID

    @State private var environments: [Arcane.Environment] = []
    @State private var pickerMode: PickerMode?
    @State private var navTarget: NavTarget?

    /// True when this page is PUSHED inside another tab's stack (e.g. from
    /// Settings) — there's a back button, so the bar can fully morph like the
    /// container/image detail pages. When Updates is itself a pinned root tab
    /// there is no way back, so the tabs stay and the actions render as
    /// accessory pills instead.
    private var isPushedDetail: Bool { currentTabID != AppTab.updates.id }

    private var runUpdaterItem: ActionButtonItem {
        ActionButtonItem(
            id: "run-updater",
            title: "Run Updater",
            systemImage: "play.fill",
            tint: .orange
        ) { launch(.runUpdater) }
    }

    private var historyItem: ActionButtonItem {
        ActionButtonItem(
            id: "updater-history",
            title: "Updater History",
            systemImage: "clock.arrow.circlepath",
            tint: .accentColor
        ) { launch(.history) }
    }

    var body: some View {
        AllEnvironmentsImageUpdatesView()
            .navigationDestination(item: $navTarget) { target in
                switch target.mode {
                case .runUpdater:
                    UpdaterRunView(environmentID: EnvironmentID(rawValue: target.envID))
                case .history:
                    UpdaterHistoryView(environmentID: EnvironmentID(rawValue: target.envID))
                }
            }
            .sheet(item: $pickerMode) { mode in
                NavigationStack {
                    EnvironmentPickerSheet(envs: environments, mode: mode) { env in
                        navTarget = NavTarget(envID: env.id, mode: mode)
                        pickerMode = nil
                    }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .modifier(UpdatesBarActions(
                isPushedDetail: isPushedDetail,
                primary: runUpdaterItem,
                secondary: historyItem
            ))
            .task { await loadEnvironments() }
    }

    private func launch(_ mode: PickerMode) {
        guard !environments.isEmpty else { return }
        if environments.count == 1, let only = environments.first {
            navTarget = NavTarget(envID: only.id, mode: mode)
        } else {
            pickerMode = mode
        }
    }

    private func loadEnvironments() async {
        guard let cached = manager.cached else { return }
        let envs: [Arcane.Environment] = (try? await cached.getListGlobal(
            "environments", elementType: Arcane.Environment.self,
            policy: .environments, refresh: false,
            onFresh: { fresh in environments = fresh }
        )) ?? []
        environments = envs
    }
}

/// Pushed inside another tab → full morph (identical to detail pages).
/// Root tab → accessory pills so the tabs stay reachable.
private struct UpdatesBarActions: ViewModifier {
    let isPushedDetail: Bool
    let primary: ActionButtonItem
    let secondary: ActionButtonItem

    func body(content: Content) -> some View {
        if isPushedDetail {
            content.morphingActions(primary: primary, inline: [secondary])
        } else {
            content.rootBarActions([primary, secondary])
        }
    }
}

enum PickerMode: String, Identifiable {
    case runUpdater
    case history
    var id: String { rawValue }

    var title: String {
        switch self {
        case .runUpdater: return "Run Updater"
        case .history: return "Updater History"
        }
    }
}

private struct NavTarget: Hashable, Identifiable {
    let envID: String
    let mode: PickerMode
    var id: String { "\(envID)-\(mode.rawValue)" }
}

private struct EnvironmentPickerSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let envs: [Arcane.Environment]
    let mode: PickerMode
    let onPick: (Arcane.Environment) -> Void

    var body: some View {
        List {
            Section {
                ForEach(envs) { env in
                    Button {
                        onPick(env)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(env.displayName)
                                    .foregroundStyle(.primary)
                                Text(env.url)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            StatusBadge(status: env.status)
                        }
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                }
            } footer: {
                Text("Pick an environment to \(mode == .runUpdater ? "run the updater on" : "view history for").")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }
}
