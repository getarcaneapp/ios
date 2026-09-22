import SwiftUI
import Arcane

struct UpdatesView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(FleetStore.self) private var fleet
    @State private var pickerMode: PickerMode?
    @State private var navTarget: NavTarget?
    @State private var showsUpdaterSheet = false
    @State private var initialUpdaterEnvironmentID: String?
    @State private var presentedEnvironments: [Arcane.Environment] = []

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
                UpdaterHistoryView(environmentID: EnvironmentID(rawValue: target.envID))
            }
            .sheet(isPresented: $showsUpdaterSheet) {
                UpdaterRunSheet(
                    environments: presentedEnvironments,
                    initialEnvironmentID: initialUpdaterEnvironmentID
                )
            }
            .sheet(item: $pickerMode) { mode in
                NavigationStack {
                    EnvironmentPickerSheet(envs: presentedEnvironments, mode: mode) { env in
                        navTarget = NavTarget(envID: env.id)
                        pickerMode = nil
                    }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .resourceActionsToolbar(
                primary: runUpdaterItem,
                secondary: [historyItem]
            )
            .task { await fleet.load(manager: manager) }
    }

    private func launch(_ mode: PickerMode) {
        let environments = fleet.environments
        guard !environments.isEmpty else {
            if let errorMessage = fleet.errorMessage { showToast(.error(errorMessage)) }
            return
        }
        presentedEnvironments = environments
        if mode == .runUpdater {
            initialUpdaterEnvironmentID = environments.count == 1 ? environments.first?.id : nil
            showsUpdaterSheet = true
            return
        }
        if environments.count == 1, let only = environments.first {
            navTarget = NavTarget(envID: only.id)
        } else {
            pickerMode = mode
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
    var id: String { envID }
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
