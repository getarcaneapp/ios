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
        let header = "\(ToolSupport.countSummary(total, singular: "volume")) in \(context.envName): \(ToolSupport.countSummary(unusedTotal, singular: "unused volume"))."

        if !filter.isEmpty {
            items = items.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        }
        if onlyUnused {
            items = items.filter { $0.inUse != true }
        }

        let lines = ToolSupport.truncatedLines(items, limit: 25, itemSingular: "volume") { volume in
            let status = volume.inUse == true ? "in use" : "unused"
            return ToolSupport.itemLine(
                name: ToolSupport.displayName(volume.name),
                status: status,
                reason: ToolSupport.safeText(volume.driver),
                next: "browse files or backups with this name",
                internalId: volume.name
            )
        }
        let body = lines.isEmpty
            ? (onlyUnused
                ? "(no unused volumes — all are in use)"
                : "(no matching volumes found in \(ToolSupport.displayName(context.envName, fallback: "environment")))")
            : lines.joined(separator: "\n")
        return "\(header)\n\(body)"
    }

    private func detailsText(name: String) async -> String {
        let v: Volume
        do {
            v = try await context.client.volumes.inspect(envID: context.envID, name: name)
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "volume “\(name)”")
        }
        var lines: [String] = []
        lines.append(ToolSupport.itemLine(name: ToolSupport.displayName(v.name), status: v.inUse == true ? "in use" : "unused"))
        lines.append("driver: \(ToolSupport.safeText(v.driver)), scope: \(ToolSupport.safeText(v.scope))")
        lines.append("mountpoint: \(ToolSupport.safeText(v.mountpoint))")
        if v.size > 0 { lines.append("size: \(ByteCountFormatter.string(fromByteCount: v.size, countStyle: .file))") }
        if !v.createdAt.isEmpty { lines.append("created: \(ToolSupport.safeText(v.createdAt))") }
        if v.inUse {
            let users = v.containers.prefix(8).joined(separator: ", ")
            let usingText = users.isEmpty ? ToolSupport.countSummary(v.containers.count, singular: "container") : users
            lines.append("in use by: \(usingText)")
        } else {
            lines.append("in use by: none")
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
        let lineCount = entries.count
        var lines = ["\(lineCount) entries at \(ToolSupport.safeText(path)) in “\(ToolSupport.displayName(name))”:"]
        for e in entries.prefix(25) {
            if e.isDirectory {
                lines.append("- dir: \(ToolSupport.safeText(e.name))/")
            } else {
                lines.append(ToolSupport.itemLine(name: ToolSupport.safeText(e.name), status: "file", health: ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file)))
            }
        }
        if entries.count > 25 { lines.append("next: +\(ToolSupport.countSummary(entries.count - 25, singular: "entry")) not shown") }
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
        let lines = ToolSupport.truncatedLines(
            backups,
            limit: 10,
            itemSingular: "backup",
            itemPlural: "backups"
        ) { backup in
            ToolSupport.itemLine(
                name: backup.createdAt,
                status: "backup",
                reason: ByteCountFormatter.string(fromByteCount: backup.size, countStyle: .file),
                internalId: backup.id
            )
        }
        return "\(ToolSupport.countSummary(backups.count, singular: "backup")) for “\(ToolSupport.displayName(name))”.\n\(lines.joined(separator: "\n"))"
    }
}
