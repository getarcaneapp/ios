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
        var header = "\(total) image(s) in \(context.envName) (\(danglingTotal) dangling)."
        // Update availability is garnish — never fail the list for it. Raw REST +
        // app-local ImageUpdateSummary, same recipe as DashboardView (the SDK's
        // typed updateSummary doesn't match the current server's shape).
        let summaryPath = context.client.rest.environmentPath(context.envID, "image-updates/summary")
        if let updates: ImageUpdateSummary = try? await context.client.rest.get(summaryPath),
           updates.imagesWithUpdates > 0 {
            header += " \(updates.imagesWithUpdates) have update(s) available."
        }

        if let filter = arguments.filter?.trimmingCharacters(in: .whitespacesAndNewlines), !filter.isEmpty {
            items = items.filter { tagOf($0).localizedCaseInsensitiveContains(filter) }
        }
        if arguments.onlyDangling == true {
            items = items.filter(isDangling)
        }

        let formatter = ByteCountFormatter()
        let shown = items.prefix(25)
        let lines = shown.map { image -> String in
            let dangling = isDangling(image) ? " (dangling)" : ""
            return "- \(tagOf(image)) [\(formatter.string(fromByteCount: image.size))]\(dangling) id=\(String(image.id.prefix(12)))"
        }
        let more = items.count > shown.count ? "\n(+\(items.count - shown.count) more not shown)" : ""
        let body: String
        if lines.isEmpty {
            body = arguments.onlyDangling == true ? "(no dangling images)" : "(no images match that filter)"
        } else {
            body = lines.joined(separator: "\n")
        }
        return "\(header)\n\(body)\(more)"
    }
}
