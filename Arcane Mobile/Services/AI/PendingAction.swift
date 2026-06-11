import Foundation
import Arcane

/// Container lifecycle verbs the assistant may stage. Plain enum (no
/// `FoundationModels` dependency) so `AIPendingAction` stays unrestricted; tools
/// parse the model's string choice into this.
enum ContainerVerb: String, CaseIterable, Sendable {
    case start, stop, restart, pause, unpause, redeploy

    var title: String {
        switch self {
        case .start: return "Start"
        case .stop: return "Stop"
        case .restart: return "Restart"
        case .pause: return "Pause"
        case .unpause: return "Resume"
        case .redeploy: return "Redeploy"
        }
    }
    /// Service-interrupting actions get the app's red extra-friction card.
    var isDestructive: Bool { self == .stop || self == .redeploy }
}

/// Compose project verbs. Raw values double as the REST path suffix
/// (`projects/{id}/{suffix}`), matching `ProjectDetailView`.
enum ProjectVerb: String, CaseIterable, Sendable {
    case up, down, restart, redeploy

    var title: String {
        switch self {
        case .up: return "Deploy"
        case .down: return "Stop"
        case .restart: return "Restart"
        case .redeploy: return "Redeploy"
        }
    }
    var isDestructive: Bool { self == .down || self == .redeploy }
}

/// A state-mutating action the model proposed, staged for the user to confirm.
/// Pure `Sendable` value type: safe to pass through the actor sink and to
/// capture in the MainActor execution closure.
///
/// `execute` reuses the confirmed-correct recipe from
/// `ContainerDetailView.performAction` / `ProjectDetailView.performSimpleAction`.
struct AIPendingAction: Identifiable, Sendable {
    let id: UUID
    let kind: Kind

    enum Kind: Sendable {
        case container(id: String, name: String, verb: ContainerVerb)
        case project(id: String, name: String, verb: ProjectVerb)
        case maintenance(MaintenanceOp)
        case update(UpdateOp)
        case task(TaskOp)
    }

    static func container(id: String, name: String, verb: ContainerVerb) -> AIPendingAction {
        AIPendingAction(id: UUID(), kind: .container(id: id, name: name, verb: verb))
    }
    static func project(id: String, name: String, verb: ProjectVerb) -> AIPendingAction {
        AIPendingAction(id: UUID(), kind: .project(id: id, name: name, verb: verb))
    }
    static func maintenance(_ op: MaintenanceOp) -> AIPendingAction {
        AIPendingAction(id: UUID(), kind: .maintenance(op))
    }
    static func update(_ op: UpdateOp) -> AIPendingAction {
        AIPendingAction(id: UUID(), kind: .update(op))
    }
    static func task(_ op: TaskOp) -> AIPendingAction {
        AIPendingAction(id: UUID(), kind: .task(op))
    }

    var displayName: String {
        switch kind {
        case let .container(_, name, _): return name
        case let .project(_, name, _): return name
        case let .maintenance(op): return op.summary
        case let .update(op): return op.summary
        case let .task(op): return op.summary
        }
    }

    var isDestructive: Bool {
        switch kind {
        case let .container(_, _, verb): return verb.isDestructive
        case let .project(_, _, verb): return verb.isDestructive
        case let .maintenance(op): return op.isDestructive
        case let .update(op): return op.isDestructive
        case let .task(op): return op.isDestructive
        }
    }

    /// Resource kinds the action touches — system prune and the updater span
    /// several, so this is a list (consumers loop).
    var mutationKinds: [ResourceMutationStore.Kind] {
        switch kind {
        case .container: return [.containers]
        case .project: return [.projects]
        case let .maintenance(op): return op.mutationKinds
        case let .update(op): return op.mutationKinds
        case let .task(op): return op.mutationKinds
        }
    }

    /// Verb title used for buttons ("Stop", "Restart", …).
    var actionTitle: String {
        switch kind {
        case let .container(_, _, verb): return verb.title
        case let .project(_, _, verb): return verb.title
        case let .maintenance(op): return op.actionTitle
        case let .update(op): return op.actionTitle
        case let .task(op): return op.actionTitle
        }
    }

    /// "Stop “redis”?" — confirmation card headline.
    var confirmationTitle: String {
        switch kind {
        case .container, .project: return "\(actionTitle) “\(displayName)”?"
        case let .maintenance(op): return op.confirmationTitle
        case let .update(op): return op.confirmationTitle
        case let .task(op): return op.confirmationTitle
        }
    }

    /// Lowercase phrase fed back to the model ("stop container redis").
    var summary: String {
        switch kind {
        case let .container(_, name, verb): return "\(verb.rawValue) container \(name)"
        case let .project(_, name, verb): return "\(verb.title.lowercased()) project \(name)"
        case let .maintenance(op): return op.summary
        case let .update(op): return op.summary
        case let .task(op): return op.summary
        }
    }

    /// Cache globs to invalidate after the action lands (same set the manual
    /// detail views invalidate).
    func cachePaths(client: ArcaneClient, envID: EnvironmentID) -> [String] {
        // One glob pair per touched resource kind, mirroring the manual views.
        func paths(for kind: ResourceMutationStore.Kind) -> [String] {
            [
                client.rest.environmentPath(envID, kind.rawValue),
                client.rest.environmentPath(envID, "\(kind.rawValue)/*")
            ]
        }
        return mutationKinds.flatMap(paths(for:))
    }

    /// Runs the real SDK call. `client`/`envID` are `Sendable`, so this is safe
    /// to await from the MainActor service after the user confirms.
    @discardableResult
    func execute(client: ArcaneClient, envID: EnvironmentID) async throws -> String {
        switch kind {
        case let .container(id, name, verb):
            switch verb {
            case .start:    try await client.containers.start(envID: envID, id: id)
            case .stop:     try await client.containers.stop(envID: envID, id: id)
            case .restart:  try await client.containers.restart(envID: envID, id: id)
            case .pause:    try await client.containers.pause(envID: envID, id: id)
            case .unpause:  try await client.containers.unpause(envID: envID, id: id)
            case .redeploy:
                let path = client.rest.environmentPath(envID, "containers/\(id)/redeploy")
                let _: ContainerSummary = try await client.rest.post(path, body: String?.none)
            }
            return "\(verb.title) succeeded for \(name)."
        case let .project(id, name, verb):
            let path = client.rest.environmentPath(envID, "projects/\(id)/\(verb.rawValue)")
            let _: DataResponse<String> = try await client.rest.post(path, body: String?.none)
            return "\(verb.title) succeeded for project \(name)."
        case let .maintenance(op):
            return try await executeMaintenance(op, client: client, envID: envID)
        case let .update(op):
            return try await executeUpdate(op, client: client, envID: envID)
        case let .task(op):
            return try await executeTask(op, client: client, envID: envID)
        }
    }

    private func executeMaintenance(_ op: MaintenanceOp, client: ArcaneClient, envID: EnvironmentID) async throws -> String {
        func reclaimed(_ bytes: UInt64) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
        switch op {
        case .pruneImages:
            let report = try await client.images.prune(envID: envID, mode: "dangling")
            return "Pruned \(report.imagesDeleted.count) image(s), reclaimed \(reclaimed(UInt64(max(0, report.spaceReclaimed))))."
        case .pruneVolumes:
            let report = try await client.volumes.prune(envID: envID)
            return "Pruned \(report.volumesDeleted.count) volume(s), reclaimed \(reclaimed(report.spaceReclaimed))."
        case .pruneNetworks:
            let report = try await client.networks.prune(envID: envID)
            return "Pruned \(report.networksDeleted.count) network(s)."
        case .pruneSystem:
            // Volumes deliberately excluded — pruning data stays a separate, explicit choice.
            let request = PruneAllRequest(
                containers: PruneContainersOptions(mode: .stopped),
                images: PruneImagesOptions(mode: .dangling),
                networks: PruneNetworksOptions(mode: .unused)
            )
            let result = try await client.system.prune(request, envID: envID)
            return "System prune complete, reclaimed \(reclaimed(result.spaceReclaimed))."
        case .startAllStopped, .startAllContainers, .stopAllContainers:
            let result: SystemContainerActionResult
            switch op {
            case .startAllStopped: result = try await client.system.startAllStoppedContainers(envID: envID)
            case .startAllContainers: result = try await client.system.startAllContainers(envID: envID)
            default: result = try await client.system.stopAllContainers(envID: envID)
            }
            let acted = (result.started?.count ?? 0) + (result.stopped?.count ?? 0)
            let failed = result.failed?.count ?? 0
            return "\(op.summary.capitalized) — \(acted) succeeded\(failed > 0 ? ", \(failed) failed" : "")."
        }
    }

    private func executeUpdate(_ op: UpdateOp, client: ArcaneClient, envID: EnvironmentID) async throws -> String {
        switch op {
        case let .pullImage(ref):
            // Split "nginx:1.27" on the last colon; a colon inside a registry
            // port (host:5000/img) only counts when it follows the final slash.
            var imageName = ref
            var tag: String? = nil
            if let colon = ref.lastIndex(of: ":"),
               ref[ref.index(after: colon)...].firstIndex(of: "/") == nil {
                imageName = String(ref[..<colon])
                tag = String(ref[ref.index(after: colon)...])
            }
            try await client.images.pull(envID: envID, options: ImagePullOptions(imageName: imageName, tag: tag))
            return "Pulled \(ref)."
        case let .updateContainer(id, name):
            let result = try await client.updater.updateContainer(id, envID: envID)
            return result.updated > 0
                ? "Updated \(name)."
                : "\(name) is already up to date (checked \(result.checked))."
        case .runUpdaterAll:
            let result = try await client.updater.run(nil, envID: envID)
            let failed = result.failed > 0 ? ", \(result.failed) failed" : ""
            return "Updater finished: checked \(result.checked), updated \(result.updated), skipped \(result.skipped)\(failed)."
        }
    }

    private func executeTask(_ op: TaskOp, client: ArcaneClient, envID: EnvironmentID) async throws -> String {
        switch op {
        case let .runJob(id, name):
            let response = try await client.jobs.run(jobID: id, envID: envID)
            return response.success ? "Job “\(name)” ran: \(response.message)" : "Job “\(name)” failed: \(response.message)"
        case let .gitopsSync(id, name):
            let result = try await client.gitops.performSync(id: id, envID: envID)
            if result.success { return "GitOps sync “\(name)” succeeded: \(result.message)" }
            return "GitOps sync “\(name)” failed: \(result.error ?? result.message)"
        case let .scanImage(id, ref):
            // App-local ScanResult + raw REST, same recipe as ImageVulnerabilitiesView.
            let path = client.rest.environmentPath(envID, "images/\(id)/vulnerabilities/scan")
            let result: ScanResult = try await client.rest.post(path, body: String?.none)
            if let s = result.summary {
                return "Scan of \(ref) complete: \(s.critical) critical, \(s.high) high, \(s.medium) medium, \(s.low) low."
            }
            return "Scan of \(ref) finished (status: \(result.status))."
        case let .cancelActivity(id, title):
            _ = try await client.activities.cancel(envID: envID, activityID: id)
            return "Cancellation requested for “\(title)”."
        }
    }
}
