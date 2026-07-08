import Foundation
import Arcane
import FoundationModels

/// Lists images in the active environment. Bounded output; uses only
/// SDK-native fields (the app's `displayName` extension is main-actor-isolated
/// and can't be touched from a tool's `call`).
@available(iOS 26, *)
struct ListImagesTool: Tool {
    let context: ArcaneToolContext

    let name = "listImages"
    let description = "List images with tag and size; header notes dangling images and available updates."

    @Generable
    struct Arguments {
        @Guide(description: "Tag substring filter.")
        var filter: String?
        @Guide(description: "Only dangling (untagged) images.")
        var onlyDangling: Bool?
    }

    func call(arguments: Arguments) async throws -> String {
        context.status.report("Checking images…")
        var items: [ImageSummary]
        do {
            items = try await context.client.images.list(
                envID: context.envID,
                query: SearchPaginationSort(start: 0, limit: 500)
            ).data
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "images")
        }

        func tagOf(_ image: ImageSummary) -> String {
            image.repoTags.first(where: { $0 != "<none>:<none>" }) ?? String(image.id.prefix(12))
        }
        func isDangling(_ image: ImageSummary) -> Bool {
            !image.repoTags.contains(where: { $0 != "<none>:<none>" })
        }

        // Totals before filtering so a zero-match filter can't read as "no images exist".
        let total = items.count
        let danglingTotal = items.count(where: isDangling)
        var header = "\(ToolSupport.countSummary(total, singular: "image")) in \(context.envName), \(ToolSupport.countSummary(danglingTotal, singular: "dangling image"))."
        // Update availability is garnish — never fail the list for it.
        if let updates = try? await context.client.images.updateSummary(envID: context.envID),
           updates.imagesWithUpdates > 0 {
            header += " \(ToolSupport.countSummary(updates.imagesWithUpdates, singular: "image update")) available."
        }

        if let filter = arguments.filter?.trimmingCharacters(in: .whitespacesAndNewlines), !filter.isEmpty {
            items = items.filter { tagOf($0).localizedCaseInsensitiveContains(filter) }
        }
        if arguments.onlyDangling == true {
            items = items.filter(isDangling)
        }

        let formatter = ByteCountFormatter()
        let lines = ToolSupport.truncatedLines(items, limit: 25, itemSingular: "image") { image -> String in
            let dangling = isDangling(image) ? " (dangling)" : ""
            let name = tagOf(image)
            let status = dangling.isEmpty ? "present" : "dangling"
            let reason = dangling.isEmpty ? "image has tags" : "no tags (dangling)"
            return ToolSupport.itemLine(
                name: ToolSupport.displayName(name),
                status: status,
                reason: reason,
                image: formatter.string(fromByteCount: image.size),
                internalId: image.id
            )
        }
        let body: String
        if lines.isEmpty {
            body = arguments.onlyDangling == true ? "(no dangling images)" : "(no images match that filter)"
        } else {
            body = lines.joined(separator: "\n")
        }
        return "\(header)\n\(body)"
    }
}
