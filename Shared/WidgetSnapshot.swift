import Foundation

/// The app-written snapshot widgets and intents render from. Deliberately a
/// plain local Codable model — NEVER persist SDK types here (the SDK is a
/// remote pinned dependency whose shapes can change under us).
nonisolated struct WidgetSnapshot: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 2
    static let maximumEnvironments = 10
    static let maximumSuggestedContainers = 20
    static let maximumCount = 1_000_000_000

    var schemaVersion: Int = WidgetSnapshot.currentSchemaVersion
    var generatedAt: Date
    /// False when no server URL is configured or the user is signed out.
    var serverConfigured: Bool
    /// Canonical origin this authenticated snapshot belongs to.
    var serverOrigin: String?
    var isDemo: Bool
    /// User's accent color (hex), mirrored from app settings for widget tinting.
    var accentHex: String?
    var activeEnvironmentID: String?
    var environments: [EnvSummary]
    /// Recently relevant containers for intent/entity suggestions (phase 2).
    var suggestedContainers: [ContainerRef]

    nonisolated struct EnvSummary: Codable, Sendable, Equatable, Identifiable {
        var id: String
        var name: String
        var online: Bool
        var running: Int
        var stopped: Int
        var total: Int
        var images: Int
        var updatesAvailable: Int
        /// Optional so snapshots written before this field existed still
        /// decode (schema stays at v1).
        var actionableVulnerabilities: Int?
    }

    nonisolated struct ContainerRef: Codable, Sendable, Equatable, Identifiable {
        var id: String
        var name: String
        var environmentID: String
    }

    /// Aggregate counts across all environments (the widget's default scope).
    var totalRunning: Int { aggregate(\.running) }
    var totalContainers: Int { aggregate(\.total) }
    var totalUpdates: Int { aggregate(\.updatesAvailable) }
    var totalVulnerabilities: Int {
        environments.reduce(0) { partial, environment in
            Self.saturatingAdd(partial, environment.actionableVulnerabilities ?? 0)
        }
    }
    var onlineEnvironments: Int { environments.count(where: \.online) }

    static func signedOut(generatedAt: Date) -> WidgetSnapshot {
        WidgetSnapshot(
            generatedAt: generatedAt,
            serverConfigured: false,
            serverOrigin: nil,
            isDemo: false,
            accentHex: nil,
            activeEnvironmentID: nil,
            environments: [],
            suggestedContainers: []
        )
    }

    /// Equality ignoring `generatedAt` — used to decide whether a rewrite is
    /// material enough to spend a WidgetCenter reload on.
    func materiallyEquals(_ other: WidgetSnapshot) -> Bool {
        var a = self, b = other
        a.generatedAt = .distantPast
        b.generatedAt = .distantPast
        return a == b
    }

    func boundedForPersistence() -> WidgetSnapshot {
        var copy = self
        copy.activeEnvironmentID = activeEnvironmentID.map { Self.boundedText($0, maximumBytes: 256) }
        copy.environments = environments.prefix(Self.maximumEnvironments).map { environment in
            var bounded = environment
            bounded.id = Self.boundedText(environment.id, maximumBytes: 256)
            bounded.name = Self.boundedText(environment.name, maximumBytes: 256)
            bounded.running = Self.boundedCount(environment.running)
            bounded.stopped = Self.boundedCount(environment.stopped)
            bounded.total = Self.boundedCount(environment.total)
            bounded.images = Self.boundedCount(environment.images)
            bounded.updatesAvailable = Self.boundedCount(environment.updatesAvailable)
            bounded.actionableVulnerabilities = environment.actionableVulnerabilities.map(Self.boundedCount)
            return bounded
        }
        copy.suggestedContainers = suggestedContainers.prefix(Self.maximumSuggestedContainers).map { container in
            var bounded = container
            bounded.id = Self.boundedText(container.id, maximumBytes: 256)
            bounded.name = Self.boundedText(container.name, maximumBytes: 256)
            bounded.environmentID = Self.boundedText(container.environmentID, maximumBytes: 256)
            return bounded
        }
        return copy
    }

    private func aggregate(_ keyPath: KeyPath<EnvSummary, Int>) -> Int {
        environments.reduce(0) { partial, environment in
            Self.saturatingAdd(partial, environment[keyPath: keyPath])
        }
    }

    private static func boundedCount(_ value: Int) -> Int {
        min(max(value, 0), maximumCount)
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let left = boundedCount(lhs)
        let right = boundedCount(rhs)
        let (sum, overflow) = left.addingReportingOverflow(right)
        return overflow ? maximumCount : min(sum, maximumCount)
    }

    private static func boundedText(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var result = String()
        var used = 0
        for character in value {
            let bytes = String(character).utf8.count
            guard used + bytes <= maximumBytes else { break }
            result.append(character)
            used += bytes
        }
        return result
    }
}
