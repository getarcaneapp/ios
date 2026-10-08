import Arcane
import SwiftUI

struct EnvironmentColorsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(FleetStore.self) private var fleet
    @State private var colors = EnvironmentColorStore.shared

    var body: some View {
        List {
            Section {
                ForEach(fleet.environments.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }) { environment in
                    EnvironmentColorPicker(environment: environment)
                    .swipeActions {
                        Button("Reset") { colors.set(nil, server: manager.serverURL, environmentID: environment.id) }
                    }
                }
            } footer: {
                Text("Colors apply to environment names and icons in resource lists. Swipe a row to reset its color.")
            }
            if let error = fleet.errorMessage {
                Text(error).foregroundStyle(.secondary)
                Button("Retry") { Task { await fleet.load(manager: manager, refresh: true) } }
            }
        }
        .navigationTitle("Environment Colors")
        .task { await fleet.load(manager: manager) }
        .overlay {
            if fleet.isLoading && fleet.environments.isEmpty { ProgressView() }
        }
    }
}

struct EnvironmentColorPicker: View {
    let environment: Arcane.Environment
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @State private var colors = EnvironmentColorStore.shared

    @State private var showCustomColor = false

    private var selectedHex: String {
        colors.hex(server: manager.serverURL, environmentID: environment.id) ?? AccentColorOption.blue.hex
    }

    private func save(_ hex: String) {
        if !colors.set(hex, server: manager.serverURL, environmentID: environment.id) {
            showToast(.info("That color is already used by another environment. Choose a different color."))
        }
    }

    var body: some View {
        HStack {
            Text(environment.displayName)
            Spacer()
            AccentColorMenu(selection: Binding(get: { selectedHex }, set: save),
                isAvailable: { colors.isAvailable($0, server: manager.serverURL, environmentID: environment.id) },
                onCustom: { showCustomColor = true })
        }
        .sheet(isPresented: $showCustomColor) {
            CustomAccentColorPicker(selection: Binding(
                get: { Color(hex: selectedHex) ?? .blue },
                set: { color in
                    let resolved = color.resolve(in: EnvironmentValues())
                    save(String(format: "#%02X%02X%02X", Int(max(0, min(1, resolved.red)) * 255), Int(max(0, min(1, resolved.green)) * 255), Int(max(0, min(1, resolved.blue)) * 255)))
                }
            ))
        }
    }
}

struct EnvironmentColorSheet: View {
    let environment: Arcane.Environment
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    EnvironmentColorPicker(environment: environment)
                    Button("Reset Color") {
                        EnvironmentColorStore.shared.set(nil, server: manager.serverURL, environmentID: environment.id)
                    }
                } footer: {
                    Text("Applies to this environment's name and icon in resource lists.")
                }
            }
            .navigationTitle("Environment Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}
