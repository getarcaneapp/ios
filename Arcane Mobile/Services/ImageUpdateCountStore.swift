import Arcane
import Observation

/// Shares the latest per-environment image-update counts between the dashboard
/// and Updates screens. Values are scoped to the active SDK client and user so
/// switching servers or accounts cannot surface old counts.
@Observable
final class ImageUpdateCountStore {
    static let shared = ImageUpdateCountStore()

    private struct Scope: Equatable {
        let transportID: ObjectIdentifier
        let userID: String
    }

    private var scope: Scope?
    private var counts: [String: Int] = [:]
    /// Counts published by an Updates screen are derived from the image rows
    /// the user sees. Dashboard summaries may fill gaps but must not replace
    /// these values when a tab reappears and starts its load task again.
    private var authoritativeEnvironmentIDs: Set<String> = []

    private init() {}

    func total(
        client: ArcaneClient?,
        userID: String?,
        environmentIDs: [EnvironmentID]
    ) -> Int? {
        guard scope == Self.scope(client: client, userID: userID) else { return nil }
        guard !environmentIDs.isEmpty else { return nil }

        var total = 0
        for environmentID in environmentIDs {
            guard let count = counts[environmentID.rawValue] else { return nil }
            total += count
        }
        return total
    }

    func setCount(
        _ count: Int,
        environmentID: EnvironmentID,
        client: ArcaneClient?,
        userID: String?
    ) {
        guard let nextScope = Self.scope(client: client, userID: userID) else { return }
        prepare(for: nextScope)
        counts[environmentID.rawValue] = count
        authoritativeEnvironmentIDs.insert(environmentID.rawValue)
    }

    func setCounts(
        _ newCounts: [String: Int],
        client: ArcaneClient?,
        userID: String?
    ) {
        guard let nextScope = Self.scope(client: client, userID: userID) else { return }
        prepare(for: nextScope)
        counts.merge(newCounts) { _, new in new }
        authoritativeEnvironmentIDs.formUnion(newCounts.keys)
    }

    func setSummaryCounts(
        _ newCounts: [String: Int],
        client: ArcaneClient?,
        userID: String?
    ) {
        guard let nextScope = Self.scope(client: client, userID: userID) else { return }
        prepare(for: nextScope)
        for (environmentID, count) in newCounts where !authoritativeEnvironmentIDs.contains(environmentID) {
            counts[environmentID] = count
        }
    }

    private func prepare(for nextScope: Scope) {
        if scope != nextScope {
            scope = nextScope
            counts.removeAll()
            authoritativeEnvironmentIDs.removeAll()
        }
    }

    private static func scope(client: ArcaneClient?, userID: String?) -> Scope? {
        guard let client else { return nil }
        return Scope(
            transportID: ObjectIdentifier(client.transport),
            userID: userID ?? "anon"
        )
    }
}
