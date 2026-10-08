import Arcane
import SwiftUI

struct FleetUpdaterRunView: View {
    let environments: [Arcane.Environment]
    var action: FleetMaintenanceAction = .update
    var startImmediately = false
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var operation = FleetOperationStore()

    var body: some View {
        List {
            if operation.results.isEmpty && startImmediately {
                ProgressView("Starting…")
            } else if operation.results.isEmpty {
                Section {
                    ForEach(environments.filter(\.enabled)) { Text($0.displayName) }
                } header: { Text("All Enabled Environments") }
                footer: { Text(action.explanation) }
                Button(action.buttonTitle) { Task { await run() } }
                    .disabled(environments.filter(\.enabled).isEmpty)
            } else {
                Section("Results") { FleetOperationResults(store: operation) }
            }
        }
        .task {
            if startImmediately { await run() }
        }
        .navigationTitle(action.title)
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(operation.isRunning)
        .toolbar {
            AppToolbarItem(placement: .confirmationAction) {
                Button(operation.results.isEmpty ? "Cancel" : "Done") { dismiss() }.disabled(operation.isRunning)
            }
        }
    }

    private func run() async {
        guard let client = manager.client else { return }
        let session = manager.clientGeneration
        await operation.run(environments: environments, isCurrent: { manager.clientGeneration == session }) { id in
            if action == .checkImages {
                let result = try await client.images.checkAllUpdates(envID: id)
                guard session == manager.clientGeneration else { return "Completed on previous connection" }
                ResourceMutationStore.shared.markChanged(kind: .images, envID: id)
                await ImageUpdateCountStore.shared.refreshCount(environmentID: id, client: client, userID: manager.currentUser?.id)
                return "Checked \(result.count) image references."
            }
            let result = try await RemoteDataLimits.runBoundedUpdater(client: client, environmentID: id)
            guard session == manager.clientGeneration else { return "Completed on previous connection" }
            for kind in [ResourceMutationStore.Kind.images, .containers, .projects] {
                ResourceMutationStore.shared.markChanged(kind: kind, envID: id)
            }
            await ImageUpdateCountStore.shared.refreshCount(environmentID: id, client: client, userID: manager.currentUser?.id)
            if result.failed > 0 || result.success == false {
                throw ArcaneError.transport("Updated \(result.updated); failed \(result.failed); skipped \(result.skipped).")
            }
            return "Updated \(result.updated); checked \(result.checked); skipped \(result.skipped)."
        }
    }
}
