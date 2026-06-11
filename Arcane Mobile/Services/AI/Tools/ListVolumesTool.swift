import Foundation
import Arcane
import FoundationModels

/// Volumes in four views: the list (default), or one volume's details, files,
/// or backups. `name` is a substring filter for list, the exact name otherwise.
@available(iOS 26, *)
struct ListVolumesTool: Tool {
    let context: ArcaneToolContext

    let name = "listVolumes"
    let description = "List volumes, or ONE volume's details, files, or backups."

    @Generable
    enum VolumeTopic {
        case list
        case details
        case files
        case backups
    }

    @Generable
    struct Arguments {
        @Guide(description: "list (default), details, files, or backups.")
        var topic: VolumeTopic?
        @Guide(description: "Volume name (filter for list, exact otherwise).")
        var name: String?
        @Guide(description: "list only: just unused volumes.")
        var onlyUnused: Bool?
        @Guide(description: "files only: directory path, default /.")
        var path: String?
    }

    func call(arguments: Arguments) async throws -> String {
        context.status.report("Checking volumes…")
        let name = arguments.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch arguments.topic ?? .list {
        case .list:
            return await listText(filter: name, onlyUnused: arguments.onlyUnused == true)
        case .details, .files, .backups:
            guard !name.isEmpty else {
                return "Pass the volume's name. Call listVolumes first if unsure."
            }
            switch arguments.topic {
            case .files: return await filesText(name: name, path: arguments.path ?? "/")
            case .backups: return await backupsText(name: name)
            default: return await detailsText(name: name)
            }
        }
    }

    private func listText(filter: String, onlyUnused: Bool) async -> String {
        var items: [Volume]
        do {
            items = try await context.client.volumes.list(
                envID: context.envID,
                query: .init(start: 0, limit: 500)
            ).data
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "volumes")
        }

        // Totals before filtering so a zero-match filter can't read as "no volumes exist".
        let total = items.count
        let unusedTotal = items.count { $0.inUse != true }
        let header = "\(total) volume(s) in \(context.envName) (\(unusedTotal) unused)."

        if !filter.isEmpty {
            items = items.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        }
        if onlyUnused {
            items = items.filter { $0.inUse != true }
        }

        let shown = items.prefix(25)
        let lines = shown.map { volume -> String in
            let usage = volume.inUse == true ? "in use" : "unused"
            return "- \(volume.name) [\(usage)] driver=\(volume.driver)"
        }
        let more = items.count > shown.count ? "\n(+\(items.count - shown.count) more not shown)" : ""
        let body: String
        if lines.isEmpty {
            body = onlyUnused
                ? "(no unused volumes — all are in use)"
                : "(no volumes match that filter)"
        } else {
            body = lines.joined(separator: "\n")
        }
        return "\(header)\n\(body)\(more)"
    }

    private func detailsText(name: String) async -> String {
        let v: Volume
        do {
            v = try await context.client.volumes.inspect(envID: context.envID, name: name)
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "volume “\(name)”")
        }
        var lines: [String] = []
        lines.append("volume: \(v.name)")
        lines.append("driver: \(v.driver), scope: \(v.scope)")
        lines.append("mountpoint: \(v.mountpoint)")
        if v.size > 0 { lines.append("size: \(ByteCountFormatter.string(fromByteCount: v.size, countStyle: .file))") }
        if !v.createdAt.isEmpty { lines.append("created: \(v.createdAt)") }
        if v.inUse {
            let users = v.containers.prefix(8).joined(separator: ", ")
            lines.append("in use by: \(users.isEmpty ? "\(v.containers.count) container(s)" : users)")
        } else {
            lines.append("in use: no")
        }
        return lines.joined(separator: "\n")
    }

    private func filesText(name: String, path: String) async -> String {
        context.status.report("Browsing volume files…")
        let entries: [FileEntry]
        do {
            entries = try await context.client.volumes.browse(envID: context.envID, name: name, path: path)
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "files in volume “\(name)” at \(path)")
        }
        if entries.isEmpty { return "(no files at \(path) in volume “\(name)”)" }
        let shown = entries.prefix(25)
        var lines = ["\(entries.count) entr(ies) at \(path) in “\(name)”:"]
        for e in shown {
            if e.isDirectory {
                lines.append("- \(e.name)/")
            } else {
                lines.append("- \(e.name) [\(ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file))]")
            }
        }
        if entries.count > shown.count { lines.append("(+\(entries.count - shown.count) more not shown)") }
        return lines.joined(separator: "\n")
    }

    private func backupsText(name: String) async -> String {
        let backups: [BackupEntry]
        do {
            backups = try await context.client.volumes.listBackups(
                envID: context.envID,
                name: name,
                query: SearchPaginationSort(start: 0, limit: 10)
            ).data
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "backups for volume “\(name)”")
        }
        if backups.isEmpty { return "No backups exist for volume “\(name)”." }
        var lines = ["\(backups.count) backup(s) for “\(name)” (most recent first):"]
        for b in backups {
            lines.append("- \(b.createdAt) [\(ByteCountFormatter.string(fromByteCount: b.size, countStyle: .file))] id=\(b.id)")
        }
        return lines.joined(separator: "\n")
    }
}
