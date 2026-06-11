import Foundation
import Arcane

/// Op vocabularies for the staged actions beyond container/project lifecycle.
/// Plain Sendable enums with no FoundationModels dependency, mirroring
/// `ContainerVerb`/`ProjectVerb` — the staging tools map @Generable arguments
/// into these before anything touches the sink.

/// Environment-wide maintenance: prunes and bulk container actions. No target
/// id, so there is nothing for the model to hallucinate.
/// `nonisolated`: staging tools read these properties from off-actor `call()`
/// bodies, so the project's main-actor default must not apply here.
nonisolated enum MaintenanceOp: String, CaseIterable, Sendable {
    case pruneImages, pruneVolumes, pruneNetworks, pruneSystem
    case startAllStopped, startAllContainers, stopAllContainers

    /// Button label on the confirmation card.
    var actionTitle: String {
        switch self {
        case .pruneImages, .pruneVolumes, .pruneNetworks, .pruneSystem: return "Prune"
        case .startAllStopped, .startAllContainers: return "Start All"
        case .stopAllContainers: return "Stop All"
        }
    }

    /// Card headline.
    var confirmationTitle: String {
        switch self {
        case .pruneImages: return "Prune unused images?"
        case .pruneVolumes: return "Prune unused volumes?"
        case .pruneNetworks: return "Prune unused networks?"
        case .pruneSystem: return "Prune system (stopped containers, dangling images, unused networks)?"
        case .startAllStopped: return "Start all stopped containers?"
        case .startAllContainers: return "Start all containers?"
        case .stopAllContainers: return "Stop ALL containers?"
        }
    }

    /// Lowercase phrase fed back to the model.
    var summary: String {
        switch self {
        case .pruneImages: return "prune unused images"
        case .pruneVolumes: return "prune unused volumes"
        case .pruneNetworks: return "prune unused networks"
        case .pruneSystem: return "prune the system"
        case .startAllStopped: return "start all stopped containers"
        case .startAllContainers: return "start all containers"
        case .stopAllContainers: return "stop all containers"
        }
    }

    /// Prunes delete data; stopping everything interrupts every service.
    var isDestructive: Bool {
        switch self {
        case .pruneImages, .pruneVolumes, .pruneNetworks, .pruneSystem, .stopAllContainers: return true
        case .startAllStopped, .startAllContainers: return false
        }
    }

    var mutationKinds: [ResourceMutationStore.Kind] {
        switch self {
        case .pruneImages: return [.images]
        case .pruneVolumes: return [.volumes]
        case .pruneNetworks: return [.networks]
        case .pruneSystem: return [.containers, .images, .networks]
        case .startAllStopped, .startAllContainers, .stopAllContainers: return [.containers]
        }
    }
}

/// Image-update operations: pull a ref, update one container, or run the
/// env-wide auto-updater.
nonisolated enum UpdateOp: Sendable {
    case pullImage(ref: String)
    case updateContainer(id: String, name: String)
    case runUpdaterAll

    var actionTitle: String {
        switch self {
        case .pullImage: return "Pull"
        case .updateContainer, .runUpdaterAll: return "Update"
        }
    }

    var confirmationTitle: String {
        switch self {
        case let .pullImage(ref): return "Pull image “\(ref)”?"
        case let .updateContainer(_, name): return "Update “\(name)” to its latest image?"
        case .runUpdaterAll: return "Run the auto-updater for every container?"
        }
    }

    var summary: String {
        switch self {
        case let .pullImage(ref): return "pull image \(ref)"
        case let .updateContainer(_, name): return "update container \(name)"
        case .runUpdaterAll: return "run the auto-updater"
        }
    }

    /// Updating recreates containers — same friction class as redeploy.
    var isDestructive: Bool {
        switch self {
        case .pullImage: return false
        case .updateContainer, .runUpdaterAll: return true
        }
    }

    var mutationKinds: [ResourceMutationStore.Kind] {
        switch self {
        case .pullImage: return [.images]
        case .updateContainer, .runUpdaterAll: return [.containers, .images]
        }
    }
}

/// Server task operations: run a job, perform a GitOps sync, start a
/// vulnerability scan, or cancel a running activity.
nonisolated enum TaskOp: Sendable {
    case runJob(id: String, name: String)
    case gitopsSync(id: String, name: String)
    case scanImage(id: String, ref: String)
    case cancelActivity(id: String, title: String)

    var actionTitle: String {
        switch self {
        case .runJob: return "Run"
        case .gitopsSync: return "Sync"
        case .scanImage: return "Scan"
        case .cancelActivity: return "Cancel It"
        }
    }

    var confirmationTitle: String {
        switch self {
        case let .runJob(_, name): return "Run job “\(name)”?"
        case let .gitopsSync(_, name): return "Perform GitOps sync “\(name)”?"
        case let .scanImage(_, ref): return "Scan “\(ref)” for vulnerabilities?"
        case let .cancelActivity(_, title): return "Cancel “\(title)”?"
        }
    }

    var summary: String {
        switch self {
        case let .runJob(_, name): return "run job \(name)"
        case let .gitopsSync(_, name): return "perform GitOps sync \(name)"
        case let .scanImage(_, ref): return "scan image \(ref) for vulnerabilities"
        case let .cancelActivity(_, title): return "cancel activity \(title)"
        }
    }

    /// A GitOps sync can redeploy/recreate containers; the rest are benign.
    var isDestructive: Bool {
        switch self {
        case .gitopsSync: return true
        case .runJob, .scanImage, .cancelActivity: return false
        }
    }

    var mutationKinds: [ResourceMutationStore.Kind] {
        switch self {
        case .gitopsSync: return [.projects, .containers]
        case .runJob, .scanImage, .cancelActivity: return []
        }
    }
}
