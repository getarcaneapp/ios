import Arcane
import SwiftUI

/// Account preferences stored on the Arcane server that also change what the
/// app shows. Web-only display preferences stay on the web.
struct AccountPreferencesView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var isSaving = false

    private enum IconCatalog: String, CaseIterable, Identifiable {
        case selfhst
        case dashboardIcons = "dashboard-icons"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .selfhst: "selfh.st"
            case .dashboardIcons: "Dashboard Icons"
            }
        }
    }

    private var iconCatalog: Binding<IconCatalog> {
        Binding(
            get: { IconCatalog(rawValue: manager.currentUser?.preferences?.iconCatalog ?? "") ?? .selfhst },
            set: { catalog in Task { await save(UserPreferences(iconCatalog: catalog.rawValue)) } }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: iconCatalog) {
                    ForEach(IconCatalog.allCases) { catalog in
                        Text(catalog.title).tag(catalog)
                    }
                } label: {
                    SettingsRow(title: "Icon Catalog", systemImage: "square.grid.2x2.fill", color: .purple)
                }
                .pickerStyle(.menu)
                .disabled(isSaving)
            } footer: {
                Text("Project and container icons come from this catalog.")
            }
        }
        .navigationTitle("Preferences")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Sends only the changed preference; the server keeps the rest.
    private func save(_ preferences: UserPreferences) async {
        guard let client = manager.client, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let updated: User = try await client.rest.put(
                "auth/me/profile", body: PreferencesUpdate(preferences: preferences))
            manager.currentUser = updated
            // Icons are resolved into cached list responses; drop them so
            // lists pick up the new catalog on their next load.
            await ResponseCache.shared.invalidateAll()
            showToast(.success("Preferences saved"))
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }
}

private nonisolated struct PreferencesUpdate: Encodable, Sendable {
    let preferences: UserPreferences
}
