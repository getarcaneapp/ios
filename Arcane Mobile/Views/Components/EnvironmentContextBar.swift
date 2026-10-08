import SwiftUI
import Arcane

extension View {
    func environmentContext(
        isVisible: Bool,
        onSelect: @escaping () -> Void
    ) -> some View {
        modifier(EnvironmentContextModifier(isVisible: isVisible, onSelect: onSelect))
    }
}

private struct EnvironmentContextModifier: ViewModifier {
    let isVisible: Bool
    let onSelect: () -> Void

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(FleetStore.self) private var fleet
    @State private var showsPicker = false

    private var selectableEnvironments: [Arcane.Environment] {
        fleet.environments
            .filter { $0.enabled || $0.id == manager.activeEnvironmentID.rawValue }
            .sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
    }

    private var activeEnvironment: Arcane.Environment? {
        selectableEnvironments.first { $0.id == manager.activeEnvironmentID.rawValue }
    }

    private var environmentSubtitle: String {
        if manager.allEnvironmentsPreview { return "All Environments · Preview" }
        guard let activeEnvironment else { return manager.activeEnvironmentName }
        return "\(activeEnvironment.displayName), \(activeEnvironment.status.capitalized)"
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        // Only resource screens own this title menu. The dashboard has its own controls.
        if !isVisible || manager.allEnvironmentsPreview {
            content
        } else if #available(iOS 26, *) {
            environmentTitleMenu(content)
                .navigationSubtitle(environmentSubtitle)
        } else {
            environmentTitleMenu(content)
        }
    }

    private func environmentTitleMenu(_ content: Content) -> some View {
        content
            .toolbarTitleMenu {
                if isVisible, !manager.allEnvironmentsPreview, selectableEnvironments.count > 1 {
                    Button {
                        showsPicker = true
                    } label: {
                        Label("Switch Environment", systemImage: "server.rack")
                    }
                }
            }
            .sheet(isPresented: $showsPicker) {
                EnvironmentContextPicker(
                    environments: selectableEnvironments,
                    activeEnvironmentID: manager.activeEnvironmentID.rawValue
                ) { environment in
                    showsPicker = false
                    guard environment.id != manager.activeEnvironmentID.rawValue else { return }
                    onSelect()
                    manager.setActiveEnvironment(
                        id: EnvironmentID(rawValue: environment.id),
                        name: environment.displayName
                    )
                }
            }
            .task(id: manager.clientGeneration) {
                if isVisible { await fleet.load(manager: manager) }
            }
    }
}

private struct EnvironmentContextPicker: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let environments: [Arcane.Environment]
    let activeEnvironmentID: String
    let onSelect: (Arcane.Environment) -> Void

    @State private var search = ""

    private var filteredEnvironments: [Arcane.Environment] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return environments }
        return environments.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.url.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List(filteredEnvironments) { environment in
                let isActive = environment.id == activeEnvironmentID
                Button {
                    onSelect(environment)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                            .foregroundStyle(.tint)
                            .frame(width: 18)
                            .opacity(isActive ? 1 : 0)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(environment.displayName)
                                .foregroundStyle(.primary)
                            Text(environment.url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        ResourceStatusBadge(status: environment.status, usesCardStyle: true)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
            .overlay {
                if filteredEnvironments.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .navigationTitle("Choose Environment")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search environments")
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct EnvironmentSwitcherToolbarButton: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(FleetStore.self) private var fleet
    @State private var showsPicker = false

    private var selectableEnvironments: [Arcane.Environment] {
        fleet.environments
            .filter { $0.enabled || $0.id == manager.activeEnvironmentID.rawValue }
            .sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
    }

    private var activeEnvironment: Arcane.Environment? {
        selectableEnvironments.first { $0.id == manager.activeEnvironmentID.rawValue }
    }

    private var statusTint: Color {
        switch activeEnvironment?.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "online", "running", "healthy": .green
        case "partial", "partially running", "starting": .orange
        case "offline", "stopped", "error", "failed", "unhealthy": .red
        default: .secondary
        }
    }

    var body: some View {
        if !manager.allEnvironmentsPreview, selectableEnvironments.count > 1 {
            Button {
                showsPicker = true
            } label: {
                Image(systemName: "server.rack")
                    .appAccentToolbarSymbol()
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(statusTint)
                            .frame(width: 7, height: 7)
                            .overlay {
                                Circle()
                                    .stroke(Color(uiColor: .systemBackground), lineWidth: 1.5)
                            }
                            .offset(x: 2, y: 2)
                    }
            }
            .accessibilityLabel("Switch Environment")
            .accessibilityValue(activeEnvironment?.displayName ?? manager.activeEnvironmentName)
            .accessibilityHint("Shows all available environments")
            .sheet(isPresented: $showsPicker) {
                EnvironmentContextPicker(
                    environments: selectableEnvironments,
                    activeEnvironmentID: manager.activeEnvironmentID.rawValue
                ) { environment in
                    showsPicker = false
                    guard environment.id != manager.activeEnvironmentID.rawValue else { return }
                    manager.setActiveEnvironment(
                        id: EnvironmentID(rawValue: environment.id),
                        name: environment.displayName
                    )
                }
            }
        }
    }
}
