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
    let description = "List Docker images in the current environment with their tag, size, and whether they're dangling (untagged). Use this to check what images exist or find unused ones."

    @Generable
    struct Arguments {
        @Guide(description: "Optional substring to match against image tags. Omit to list all.")
        var filter: String?
        @Guide(description: "If true, only return dangling (untagged) images.")
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
            return "Couldn't list images: \(error.localizedDescription)"
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
        let header = "\(total) image(s) in \(context.envName) (\(danglingTotal) dangling)."

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
