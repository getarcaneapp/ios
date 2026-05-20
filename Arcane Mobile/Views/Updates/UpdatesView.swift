import SwiftUI
import Arcane

struct UpdatesView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager

    @State private var onlineEnvs: [Arcane.Environment] = []
    @State private var pickerMode: PickerMode?
    @State private var navTarget: NavTarget?

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
                    EnvironmentPickerSheet(envs: onlineEnvs, mode: mode) { env in
                        navTarget = NavTarget(envID: env.id, mode: mode)
                        pickerMode = nil
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .actionToolbar(
                items: [
                    ActionButtonItem(
                        id: "run-updater",
                        title: "Run Updater",
                        systemImage: "play.fill",
                        tint: .orange
                    ) { launch(.runUpdater) },
                    ActionButtonItem(
                        id: "updater-history",
                        title: "Updater History",
                        systemImage: "clock.arrow.circlepath",
                        tint: .accentColor
                    ) { launch(.history) }
                ],
                isDisabled: onlineEnvs.isEmpty
            )
            .task { await loadOnlineEnvs() }
    }

    private func launch(_ mode: PickerMode) {
        guard !onlineEnvs.isEmpty else { return }
        if onlineEnvs.count == 1, let only = onlineEnvs.first {
            navTarget = NavTarget(envID: only.id, mode: mode)
        } else {
            pickerMode = mode
        }
    }

    private func loadOnlineEnvs() async {
        guard let cached = manager.cached else { return }
        let envs: [Arcane.Environment] = (try? await cached.getListGlobal(
            "environments", elementType: Arcane.Environment.self,
            policy: .environments, refresh: false,
            onFresh: { fresh in onlineEnvs = fresh.filter { $0.isOnline ?? false } }
        )) ?? []
        onlineEnvs = envs.filter { $0.isOnline ?? false }
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
