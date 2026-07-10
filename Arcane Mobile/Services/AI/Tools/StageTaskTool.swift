import Foundation
import Arcane
import FoundationModels

/// Stages every mutation behind one schema. Consolidating lifecycle,
/// maintenance, and task actions saves three permanent schemas in the model's
/// small context window while retaining the same confirmation behavior.
@available(iOS 26, *)
struct StageTaskTool: Tool {
    let context: ArcaneToolContext
    let sink: AIPendingActionSink

    let name = "stageTask"
    let description = "Stage a container, project, maintenance, update, or server task for user confirmation. "
        + "Never executes."

    @Generable
    enum TaskAction: Sendable {
        case containerStart
        case containerStop
        case containerRestart
        case containerPause
        case containerUnpause
        case containerRedeploy
        case projectUp
        case projectDown
        case projectRestart
        case projectRedeploy
        case pruneImages
        case pruneVolumes
        case pruneNetworks
        case pruneSystem
        case startAllStopped
        case startAllContainers
        case stopAllContainers
        case pullImage
        case updateContainer
        case runUpdaterAll
        case runJob
        case gitopsSync
        case scanImage
        case cancelActivity
    }

    @Generable
    struct Arguments: Sendable {
        @Guide(description: "The task to stage.")
        var action: TaskAction
        @Guide(description: "Target id or image ref; omit for environment-wide actions.")
        var target: String?
        @Guide(description: "Human-readable name for the confirmation prompt.")
        var targetName: String?
    }

    func call(arguments: Arguments) async throws -> String {
        context.status.report("Preparing task…")
        let target = arguments.target?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let targetName = arguments.targetName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let staged = "Awaiting user confirmation — do not assume it has run."

        if let verb = containerVerb(for: arguments.action) {
            guard !target.isEmpty else { return "Container actions need an id — call listContainers first." }
            guard !targetName.isEmpty else { return "Container actions need targetName for the prompt." }
            await sink.register(.container(id: target, name: targetName, verb: verb))
            return "Staged \(verb.rawValue) for “\(targetName)”. \(staged)"
        }

        if let verb = projectVerb(for: arguments.action) {
            guard !target.isEmpty else { return "Project actions need an id — call listProjects first." }
            guard !targetName.isEmpty else { return "Project actions need targetName for the prompt." }
            await sink.register(.project(id: target, name: targetName, verb: verb))
            return "Staged \(verb.rawValue) for project “\(targetName)”. \(staged)"
        }

        if let operation = maintenanceOperation(for: arguments.action) {
            await sink.register(.maintenance(operation))
            return "Staged: \(operation.summary) on \(context.envName). \(staged)"
        }

        return await stageTargetedTask(
            action: arguments.action,
            target: target,
            targetName: targetName,
            staged: staged
        )
    }

    private func containerVerb(for action: TaskAction) -> ContainerVerb? {
        switch action {
        case .containerStart: .start
        case .containerStop: .stop
        case .containerRestart: .restart
        case .containerPause: .pause
        case .containerUnpause: .unpause
        case .containerRedeploy: .redeploy
        default: nil
        }
    }

    private func projectVerb(for action: TaskAction) -> ProjectVerb? {
        switch action {
        case .projectUp: .up
        case .projectDown: .down
        case .projectRestart: .restart
        case .projectRedeploy: .redeploy
        default: nil
        }
    }

    private func maintenanceOperation(for action: TaskAction) -> MaintenanceOp? {
        switch action {
        case .pruneImages: .pruneImages
        case .pruneVolumes: .pruneVolumes
        case .pruneNetworks: .pruneNetworks
        case .pruneSystem: .pruneSystem
        case .startAllStopped: .startAllStopped
        case .startAllContainers: .startAllContainers
        case .stopAllContainers: .stopAllContainers
        default: nil
        }
    }

    private func stageTargetedTask(
        action: TaskAction,
        target: String,
        targetName: String,
        staged: String
    ) async -> String {
        switch action {
        case .pullImage:
            return await stageImagePull(target: target, staged: staged)
        case .updateContainer:
            return await stageContainerUpdate(target: target, targetName: targetName, staged: staged)
        case .runUpdaterAll:
            return await stageUpdater(staged: staged)
        case .runJob:
            return await stageJob(target: target, staged: staged)
        case .gitopsSync:
            return await stageGitOpsSync(target: target, staged: staged)
        case .scanImage:
            return await stageImageScan(target: target, targetName: targetName, staged: staged)
        case .cancelActivity:
            return await stageActivityCancellation(target: target, staged: staged)
        default:
            return "That action could not be staged."
        }
    }

    private func stageImagePull(target: String, staged: String) async -> String {
        guard !target.isEmpty else { return "pullImage needs a target image ref like nginx:latest." }
        await sink.register(.update(.pullImage(ref: target)))
        return "Staged: pull \(target). \(staged) The pull may take a minute once confirmed."
    }

    private func stageContainerUpdate(target: String, targetName: String, staged: String) async -> String {
        guard !target.isEmpty else {
            return "updateContainer needs the container's id — call listContainers first."
        }
        let resolved: ContainerDetails
        do {
            resolved = try await context.client.containers.inspect(envID: context.envID, id: target)
        } catch {
            return "No container with id “\(target)” — call listContainers and use an id from there."
        }
        let name = targetName.isEmpty
            ? resolved.name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : targetName
        await sink.register(.update(.updateContainer(id: target, name: name)))
        return "Staged: update \(name) to its latest image. \(staged)"
    }

    private func stageUpdater(staged: String) async -> String {
        await sink.register(.update(.runUpdaterAll))
        return "Staged: run the auto-updater for every container in \(context.envName). \(staged)"
    }

    private func stageJob(target: String, staged: String) async -> String {
        guard !target.isEmpty else { return "runJob needs the job's id — read jobs first." }
        let jobs = (try? await context.client.jobs.list(envID: context.envID))?.jobs ?? []
        guard let job = jobs.first(where: { $0.id == target }) else {
            return "No job with id “\(target)” — read jobs first."
        }
        guard job.canRunManually else { return "Job “\(job.name)” can't be run manually." }
        await sink.register(.task(.runJob(id: job.id, name: job.name)))
        return "Staged: run job “\(job.name)”. \(staged)"
    }

    private func stageGitOpsSync(target: String, staged: String) async -> String {
        guard !target.isEmpty else { return "gitopsSync needs the sync's id — read GitOps first." }
        let sync: GitOpsSync
        do {
            sync = try await context.client.gitops.getSync(id: target, envID: context.envID)
        } catch {
            return "No GitOps sync with id “\(target)” — read GitOps first."
        }
        await sink.register(.task(.gitopsSync(id: sync.id, name: sync.name)))
        return "Staged: perform GitOps sync “\(sync.name)”. \(staged)"
    }

    private func stageImageScan(target: String, targetName: String, staged: String) async -> String {
        guard !target.isEmpty else { return "scanImage needs the image's id — call listImages first." }
        let image: ImageDetailSummary
        do {
            image = try await context.client.images.inspect(envID: context.envID, id: target)
        } catch {
            return "No image with id “\(target)” — call listImages and use an id from there."
        }
        let reference = targetName.isEmpty
            ? image.repoTags.first(where: { $0 != "<none>:<none>" }) ?? String(image.id.prefix(12))
            : targetName
        await sink.register(.task(.scanImage(id: target, ref: reference)))
        return "Staged: scan \(reference) for vulnerabilities. \(staged)"
    }

    private func stageActivityCancellation(target: String, staged: String) async -> String {
        guard context.capabilities.supportsActivities else {
            return "Activity cancellation is not supported by this server."
        }
        guard !target.isEmpty else { return "cancelActivity needs an id — call recentActivities first." }
        let detail: ActivityDetail
        do {
            detail = try await context.client.activities.detail(
                envID: context.envID,
                activityID: target,
                limit: 1
            )
        } catch {
            return "No activity with id “\(target)” — call recentActivities first."
        }
        let activity = detail.activity
        guard activity.status == .running || activity.status == .queued else {
            return "Activity “\(activity.displayTitle)” is \(activity.status.rawValue); "
                + "only active work can be cancelled."
        }
        await sink.register(.task(.cancelActivity(id: target, title: activity.displayTitle)))
        return "Staged: cancel “\(activity.displayTitle)”. \(staged)"
    }
}
