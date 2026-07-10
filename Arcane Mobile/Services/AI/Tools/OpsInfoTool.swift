import Foundation
import Arcane
import FoundationModels

/// Long-tail server-configuration reads behind one topic enum, so nine rare
/// lookups cost the model a single tool schema instead of nine.
/// Secrets discipline: webhook tokens/URLs and notification configs are never
/// echoed — names, providers, and enabled-state only.
@available(iOS 26, *)
struct GetOpsInfoTool: Tool {
    let context: ArcaneToolContext

    let name = "getOpsInfo"
    let description = "Server configuration: registries, templates, jobs, updater, webhooks, notifications, builds, or GitOps status. Pick one topic."

    @Generable
    enum OpsTopic: Sendable {
        case registries
        case templates
        case templateContent
        case jobs
        case updater
        case webhooks
        case notifications
        case builds
        case gitops
    }

    @Generable
    struct Arguments: Sendable {
        @Guide(description: "Which list to read.")
        var topic: OpsTopic
        @Guide(description: "Template id, or GitOps sync id for detail.")
        var id: String?
    }

    func call(arguments: Arguments) async throws -> String {
        context.status.report("Reading server configuration…")
        switch arguments.topic {
        case .registries: return await registriesText()
        case .templates: return await templatesText()
        case .templateContent: return await templateContentText(id: arguments.id)
        case .jobs: return await jobsText()
        case .updater: return await updaterText()
        case .webhooks: return await webhooksText()
        case .notifications: return await notificationsText()
        case .builds: return await buildsText()
        case .gitops: return await gitopsText(syncId: arguments.id)
        }
    }

    private func registriesText() async -> String {
        do {
            let items = try await context.client.registries.listPaginated(start: 0, limit: 25).data
            if items.isEmpty { return "No container registries configured." }
            var lines = ["\(items.count) container registr(ies):"]
            for r in items {
                let state = r.enabled ? "enabled" : "disabled"
                lines.append("- \(ToolSupport.maskedHost(r.url)) [\(r.registryType), \(state)]")
            }
            return lines.joined(separator: "\n")
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "container registries")
        }
    }

    private func templatesText() async -> String {
        do {
            let items = try await context.client.templates.listAll()
            if items.isEmpty { return "No templates available." }
            var lines = ["\(items.count) template(s):"]
            for t in items.prefix(15) {
                let kind = t.isRemote ? "remote" : "local"
                lines.append("- \(t.name) [\(kind)] \(String(t.description.prefix(60))) id=\(t.id)")
            }
            if items.count > 15 { lines.append("(+\(items.count - 15) more not shown)") }
            return lines.joined(separator: "\n")
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "templates")
        }
    }

    private func templateContentText(id: String?) async -> String {
        guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            return "Pass the template's id (from topic=templates) to read its content."
        }
        do {
            let t = try await context.client.templates.get(id: id)
            let clipped = t.content.count > 3000 ? String(t.content.prefix(3000)) + "\n(truncated)" : t.content
            return "Template \(t.name):\n\(clipped)"
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "template “\(id)”")
        }
    }

    private func jobsText() async -> String {
        do {
            let response = try await context.client.jobs.list(envID: context.envID)
            if response.jobs.isEmpty { return "No background jobs on this server." }
            var lines = ["\(response.jobs.count) background job(s):"]
            let formatter = RelativeDateTimeFormatter()
            for j in response.jobs.prefix(15) {
                let state = j.enabled ? "enabled" : "disabled"
                let next = j.nextRun.map { ", next " + formatter.localizedString(for: $0, relativeTo: Date()) } ?? ""
                lines.append("- \(j.name) [\(state)\(next)] schedule=\(j.schedule) id=\(j.id)")
            }
            if response.jobs.count > 15 { lines.append("(+\(response.jobs.count - 15) more not shown)") }
            return lines.joined(separator: "\n")
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "background jobs")
        }
    }

    private func updaterText() async -> String {
        do {
            let status = try await context.client.updater.status(envID: context.envID)
            var lines: [String] = []
            if status.updatingContainers > 0 || status.updatingProjects > 0 {
                lines.append("Updater is running: \(status.updatingContainers) container(s), \(status.updatingProjects) project(s) updating now.")
            } else {
                lines.append("Updater is idle.")
            }
            if let history = try? await context.client.updater.history(limit: 10, envID: context.envID), !history.isEmpty {
                lines.append("Recent auto-update runs:")
                let formatter = RelativeDateTimeFormatter()
                for r in history.prefix(10) {
                    let when = formatter.localizedString(for: r.startTime, relativeTo: Date())
                    let applied = r.updateApplied ? "updated" : (r.updateAvailable ? "update available" : "up to date")
                    lines.append("- \(r.resourceName) [\(applied)] \(when)")
                }
            }
            return lines.joined(separator: "\n")
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "the auto-updater")
        }
    }

    private func webhooksText() async -> String {
        do {
            let items = try await context.client.webhooks.list(envID: context.envID)
            if items.isEmpty { return "No webhooks configured in \(context.envName)." }
            var lines = ["\(items.count) webhook(s):"]
            for w in items.prefix(15) {
                let state = w.enabled ? "enabled" : "disabled"
                let target = w.targetName ?? w.targetType
                lines.append("- \(w.name) [\(state)] \(w.actionType) → \(target)")
            }
            if items.count > 15 { lines.append("(+\(items.count - 15) more not shown)") }
            return lines.joined(separator: "\n")
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "webhooks")
        }
    }

    private func notificationsText() async -> String {
        do {
            let items = try await context.client.notifications.listSettings(envID: context.envID)
            if items.isEmpty { return "No notification providers configured." }
            let lines = items.map { "- \($0.provider.rawValue) [\($0.enabled ? "enabled" : "disabled")]" }
            return "\(items.count) notification provider(s):\n" + lines.joined(separator: "\n")
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "notification settings")
        }
    }

    private func buildsText() async -> String {
        do {
            let items = try await context.client.images.listBuilds(
                envID: context.envID,
                query: SearchPaginationSort(start: 0, limit: 10)
            ).data
            if items.isEmpty { return "No image builds recorded." }
            var lines = ["\(items.count) recent image build(s):"]
            for b in items {
                let tag = b.tags?.first ?? b.contextDir
                lines.append("- \(tag) [\(b.status)]")
            }
            return lines.joined(separator: "\n")
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "image builds")
        }
    }

    // MARK: - GitOps (overview, or one sync's detail when an id is given)

    private func gitopsText(syncId: String?) async -> String {
        context.status.report("Checking GitOps…")
        if let id = syncId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return await gitopsSyncDetailText(id: id)
        }
        let syncs: [GitOpsSync]
        do {
            syncs = try await context.client.gitops.listSyncsPaginated(
                start: 0,
                limit: 50,
                envID: context.envID
            ).data
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "GitOps syncs")
        }
        // Repos are global config — garnish for the header only.
        let repoCount = (try? await context.client.gitops.listRepositoriesPaginated(start: 0, limit: 50))?.data.count

        if syncs.isEmpty {
            let repos = repoCount.map { " (\($0) git repositor(ies) configured)" } ?? ""
            return "No GitOps syncs configured in \(context.envName)\(repos)."
        }
        let failing = syncs.count { ($0.lastSyncStatus ?? "").lowercased().contains("fail") || $0.lastSyncError != nil }
        var lines = ["\(syncs.count) GitOps sync(s) in \(context.envName), \(failing) failing."]
        let formatter = RelativeDateTimeFormatter()
        for s in syncs.prefix(20) {
            let repo = s.repository.map { ToolSupport.maskedHost($0.url) } ?? "?"
            let status = s.lastSyncStatus ?? "never synced"
            let when = s.lastSyncAt.map { " " + formatter.localizedString(for: $0, relativeTo: Date()) } ?? ""
            lines.append("- \(s.name) [\(status)\(when)] \(repo)@\(s.branch) → \(s.projectName) id=\(s.id)")
        }
        if syncs.count > 20 { lines.append("(+\(syncs.count - 20) more not shown)") }
        return lines.joined(separator: "\n")
    }

    private func gitopsSyncDetailText(id: String) async -> String {
        let sync: GitOpsSync
        do {
            sync = try await context.client.gitops.getSync(id: id, envID: context.envID)
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "GitOps sync “\(id)”")
        }
        var lines: [String] = []
        lines.append("sync: \(sync.name)")
        if let repo = sync.repository { lines.append("repository: \(ToolSupport.maskedHost(repo.url)) (\(repo.name))") }
        lines.append("branch: \(sync.branch), composePath: \(sync.composePath)")
        lines.append("project: \(sync.projectName)")
        lines.append("autoSync: \(sync.autoSync ? "every \(sync.syncInterval) min" : "off")")
        if let status = try? await context.client.gitops.getSyncStatus(id: id, envID: context.envID) {
            lines.append("lastSync: \(status.lastSyncStatus ?? "never")")
            if let commit = status.lastSyncCommit { lines.append("lastCommit: \(String(commit.prefix(12)))") }
            if let error = status.lastSyncError, !error.isEmpty { lines.append("lastError: \(String(error.prefix(300)))") }
            if let next = status.nextSyncAt {
                lines.append("nextSync: \(RelativeDateTimeFormatter().localizedString(for: next, relativeTo: Date()))")
            }
        } else if let error = sync.lastSyncError, !error.isEmpty {
            lines.append("lastError: \(String(error.prefix(300)))")
        }
        return lines.joined(separator: "\n")
    }
}
