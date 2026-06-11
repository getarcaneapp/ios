import Foundation
import Arcane
import FoundationModels

/// Stages every non-lifecycle targeted action behind one schema: image pulls,
/// container updates, the env-wide updater, jobs, GitOps syncs, vulnerability
/// scans, and activity cancellation. Targets are validated with a cheap read
/// BEFORE staging, so a hallucinated id never reaches a confirmation card.
@available(iOS 26, *)
struct StageTaskTool: Tool {
    let context: ArcaneToolContext
    let sink: AIPendingActionSink

    let name = "stageTask"
    let description = """
    Stage for user confirmation: pullImage (target=image ref), updateContainer (container id), \
    runUpdaterAll, runJob (id from getOpsInfo jobs), gitopsSync (id from getOpsInfo gitops), \
    scanImage (image id), cancelActivity (id from recentActivities). Never executes.
    """

    @Generable
    enum TaskAction {
        case pullImage
        case updateContainer
        case runUpdaterAll
        case runJob
        case gitopsSync
        case scanImage
        case cancelActivity
    }

    @Generable
    struct Arguments {
        @Guide(description: "The task to stage.")
        var action: TaskAction
        @Guide(description: "Target id or image ref (not needed for runUpdaterAll).")
        var target: String?
        @Guide(description: "Human-readable name for the confirmation prompt.")
        var targetName: String?
    }

    func call(arguments: Arguments) async throws -> String {
        context.status.report("Preparing task…")
        let target = arguments.target?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let staged = "Awaiting user confirmation — do not assume it has run."

        switch arguments.action {
        case .pullImage:
            guard !target.isEmpty else { return "pullImage needs a target image ref like nginx:latest." }
            await sink.register(.update(.pullImage(ref: target)))
            return "Staged: pull \(target). \(staged) The pull may take a minute once confirmed."

        case .updateContainer:
            guard !target.isEmpty else { return "updateContainer needs the container's id — call listContainers first." }
            let resolved: ContainerDetails
            do {
                resolved = try await context.client.containers.inspect(envID: context.envID, id: target)
            } catch {
                return "No container with id “\(target)” — call listContainers and use an id from there."
            }
            let name = arguments.targetName
                ?? resolved.name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            await sink.register(.update(.updateContainer(id: target, name: name)))
            return "Staged: update \(name) to its latest image. \(staged) The update may take a minute once confirmed."

        case .runUpdaterAll:
            await sink.register(.update(.runUpdaterAll))
            return "Staged: run the auto-updater for every container in \(context.envName). \(staged) This may take a few minutes once confirmed."

        case .runJob:
            guard !target.isEmpty else { return "runJob needs the job's id — call getOpsInfo with topic=jobs first." }
            let jobs = (try? await context.client.jobs.list(envID: context.envID))?.jobs ?? []
            guard let job = jobs.first(where: { $0.id == target }) else {
                return "No job with id “\(target)” — call getOpsInfo with topic=jobs first."
            }
            guard job.canRunManually else { return "Job “\(job.name)” can't be run manually." }
            await sink.register(.task(.runJob(id: job.id, name: job.name)))
            return "Staged: run job “\(job.name)”. \(staged)"

        case .gitopsSync:
            guard !target.isEmpty else { return "gitopsSync needs the sync's id — call getOpsInfo with topic=gitops first." }
            let sync: GitOpsSync
            do {
                sync = try await context.client.gitops.getSync(id: target, envID: context.envID)
            } catch {
                return "No GitOps sync with id “\(target)” — call getOpsInfo with topic=gitops first."
            }
            await sink.register(.task(.gitopsSync(id: sync.id, name: sync.name)))
            return "Staged: perform GitOps sync “\(sync.name)”. \(staged)"

        case .scanImage:
            guard !target.isEmpty else { return "scanImage needs the image's id — call listImages first." }
            let image: ImageDetailSummary
            do {
                image = try await context.client.images.inspect(envID: context.envID, id: target)
            } catch {
                return "No image with id “\(target)” — call listImages and use an id from there."
            }
            let ref = arguments.targetName
                ?? image.repoTags.first(where: { $0 != "<none>:<none>" })
                ?? String(image.id.prefix(12))
            await sink.register(.task(.scanImage(id: target, ref: ref)))
            return "Staged: scan \(ref) for vulnerabilities. \(staged) The scan may take a minute once confirmed."

        case .cancelActivity:
            guard !target.isEmpty else { return "cancelActivity needs the activity's id — call recentActivities first." }
            let detail: ActivityDetail
            do {
                detail = try await context.client.activities.detail(envID: context.envID, activityID: target, limit: 1)
            } catch {
                return "No activity with id “\(target)” — call recentActivities first."
            }
            let a = detail.activity
            guard a.status == .running || a.status == .queued else {
                return "Activity “\(a.displayTitle)” is \(a.status.rawValue) — only running or queued activities can be cancelled."
            }
            await sink.register(.task(.cancelActivity(id: target, title: a.displayTitle)))
            return "Staged: cancel “\(a.displayTitle)”. \(staged)"
        }
    }
}
