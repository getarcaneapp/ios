import Arcane
import SwiftUI

// Shared helpers for the Swarm screens. Swarm specs come back as raw Docker
// JSON (`JSONValue`), so these read the few fields the UI shows.

extension JSONValue {
    nonisolated subscript(key: String) -> JSONValue? {
        swarmObject?[key]
    }

    nonisolated var swarmObject: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    nonisolated var swarmArray: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// Docker's `{ "Index": N }` object version.
    nonisolated var swarmVersionIndex: UInt64? {
        guard case .number(let index)? = self["Index"], index >= 0, index.isFinite else { return nil }
        return UInt64(index)
    }

    nonisolated var swarmString: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

nonisolated enum SwarmPresentation {
    /// Maps Docker swarm states onto the status vocabulary `ResourceStatusBadge` colors.
    static func badgeStatus(for state: String) -> String {
        switch state.lowercased() {
        case "running", "ready", "active", "reachable", "connected": "running"
        case "pending", "assigned", "accepted", "preparing", "starting", "new", "allocated", "ready_pending":
            "starting"
        case "failed", "rejected", "down", "unreachable", "orphaned", "mismatched": "failed"
        case "complete", "completed": "completed"
        case "shutdown", "remove", "drain", "disconnected", "offline": "stopped"
        case "pause": "paused"
        default: state
        }
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Status chip for swarm states (task, node, availability).
struct SwarmStateBadge: View {
    let state: String
    var usesCardStyle = true

    var body: some View {
        ResourceStatusBadge(
            status: SwarmPresentation.badgeStatus(for: state),
            isLive: false,
            usesCardStyle: usesCardStyle,
            label: state.replacingOccurrences(of: "_", with: " ").capitalized
        )
    }
}

/// Error / empty / loading wrapper shared by the swarm lists.
struct SwarmListState<Content: View>: View {
    let isLoading: Bool
    let isEmpty: Bool
    let errorMessage: String?
    let emptyTitle: String
    let emptySystemImage: String
    var emptyDescription: String? = nil
    let retry: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        if isLoading && isEmpty {
            ArcaneLoadingView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, isEmpty {
            ContentUnavailableView {
                Label("Couldn't Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again", action: retry)
            }
        } else if isEmpty {
            ContentUnavailableView(
                emptyTitle,
                systemImage: emptySystemImage,
                description: emptyDescription.map { Text($0) }
            )
        } else {
            content()
        }
    }
}

/// Sets the navigation title only for standalone screens, so embedded lists
/// don't override their parent's title.
struct SwarmTitleModifier: ViewModifier {
    let title: String?

    func body(content: Content) -> some View {
        if let title {
            content.navigationTitle(title)
        } else {
            content
        }
    }
}

/// Key / value rows (labels, env) with an empty fallback.
struct SwarmKeyValueRows: View {
    let pairs: [(String, String)]

    var body: some View {
        ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
            LabeledContent(pair.0) {
                Text(verbatim: pair.1)
                    .font(.callout.monospaced())
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
    }
}

extension ArcaneClientManager {
    /// Invalidates cached swarm lists and bumps the swarm mutation version.
    func swarmChanged(_ environmentID: EnvironmentID, mutationStore: ResourceMutationStore) async {
        if let cached, let client {
            await cached.invalidate(
                envID: environmentID, paths: [client.rest.environmentPath(environmentID, "swarm") + "*"])
        }
        mutationStore.markChanged(kind: .swarm, envID: environmentID)
    }
}
