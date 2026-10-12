import Arcane
import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class AllEnvironmentsOperationStore {
    static let shared = AllEnvironmentsOperationStore()
    private(set) var results: [EnvironmentOperationResult] = []
    private(set) var isRunning = false

    func run(
        environments: [Arcane.Environment], isCurrent: () -> Bool,
        operation: (EnvironmentID) async throws -> String
    ) async {
        guard !isRunning, results.isEmpty else { return }
        results = environments.filter(\.enabled).map { .init(id: $0.id, name: $0.displayName) }
        isRunning = true
        defer { isRunning = false }
        for index in results.indices {
            guard !Task.isCancelled, isCurrent() else {
                for remaining in index..<results.count {
                    results[remaining].status = "Not started: connection changed or operation cancelled"
                    results[remaining].failed = true
                    results[remaining].finished = true
                }
                return
            }
            results[index].status = "Running…"
            do {
                results[index].status = try await operation(EnvironmentID(rawValue: results[index].id))
            } catch {
                results[index].status = friendlyErrorMessage(error)
                results[index].failed = true
            }
            results[index].finished = true
        }
    }

    func performMaintenance(
        _ action: AllEnvironmentsMaintenanceAction, environments: [Arcane.Environment], manager: ArcaneClientManager
    ) async {
        guard let client = manager.client else { return }
        let session = manager.clientGeneration
        await runWithToast(
            title: action.progressTitle, completionTitle: action.completionTitle, symbol: action.systemImage,
            environments: environments, isCurrent: { manager.clientGeneration == session }
        ) { id in
            if action == .checkImages {
                let result = try await client.images.checkAllUpdates(envID: id)
                guard session == manager.clientGeneration else { return "Completed on previous connection" }
                ResourceMutationStore.shared.markChanged(kind: .images, envID: id)
                await ImageUpdateCountStore.shared.refreshCount(
                    environmentID: id, client: client, userID: manager.currentUser?.id)
                return "Checked \(result.count) image references."
            }
            let result = try await RemoteDataLimits.runBoundedUpdater(client: client, environmentID: id)
            guard session == manager.clientGeneration else { return "Completed on previous connection" }
            for kind in [ResourceMutationStore.Kind.images, .containers, .projects] {
                ResourceMutationStore.shared.markChanged(kind: kind, envID: id)
            }
            await ImageUpdateCountStore.shared.refreshCount(
                environmentID: id, client: client, userID: manager.currentUser?.id)
            if result.failed > 0 || result.success == false {
                throw ArcaneError.transport(
                    "Updated \(result.updated); failed \(result.failed); skipped \(result.skipped).")
            }
            return "Updated \(result.updated); checked \(result.checked); skipped \(result.skipped)."
        }
    }

    func performPrune(
        _ action: ResourcePruneAction, environments: [Arcane.Environment], manager: ArcaneClientManager
    ) async {
        guard let client = manager.client else { return }
        let session = manager.clientGeneration
        await runWithToast(
            title: "Pruning \(action.resourceName)…", completionTitle: "\(action.resourceName.capitalized) pruned",
            symbol: "trash", isDestructive: true,
            environments: environments, isCurrent: { manager.clientGeneration == session }
        ) { id in
            guard manager.permissions.has(action.permission, in: id) else {
                throw ArcaneError.transport("Not run: no prune permission")
            }
            try await action.perform(client: client, environmentID: id)
            guard session == manager.clientGeneration else { return "Completed on previous connection" }
            await ResponseCache.shared.invalidateEnvironment(id.rawValue)
            ResourceMutationStore.shared.markChanged(kind: action.mutationKind, envID: id)
            return "\(action.resourceName.capitalized) pruned"
        }
    }

    func runWithToast(
        title: String, completionTitle: String? = nil, symbol: String = "arrow.triangle.2.circlepath",
        isDestructive: Bool = false,
        environments: [Arcane.Environment], isCurrent: () -> Bool,
        operation: (EnvironmentID) async throws -> String
    ) async {
        guard !isRunning else {
            showToast(.info("An action is already running."))
            return
        }
        guard environments.contains(where: \.enabled) else {
            showToast(.info("No enabled environments."))
            return
        }
        results = []
        showToast(
            Toast(
                title: title, duration: 2.5, symbol: symbol, symbolTint: isDestructive ? .red : .accentColor,
                isPersistent: true))
        await run(environments: environments, isCurrent: isCurrent, operation: operation)
        let failed = results.filter(\.failed).count
        let succeeded = results.filter { $0.finished && !$0.failed }.count
        let message =
            failed == 0
            ? (completionTitle ?? "\(title) complete")
            : "\(succeeded) succeeded, \(failed) failed"
        showToast(failed == 0 ? .success(message) : .error(message))
    }
}
