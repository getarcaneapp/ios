import Foundation

/// The app-written snapshot widgets and intents render from. Deliberately a
/// plain local Codable model — NEVER persist SDK types here (the SDK is a
/// remote pinned dependency whose shapes can change under us).
nonisolated struct WidgetSnapshot: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = WidgetSnapshot.currentSchemaVersion
    var generatedAt: Date
    /// False when no server URL is configured or the user is signed out.
    var serverConfigured: Bool
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
    var totalRunning: Int { environments.reduce(0) { $0 + $1.running } }
    var totalContainers: Int { environments.reduce(0) { $0 + $1.total } }
    var totalUpdates: Int { environments.reduce(0) { $0 + $1.updatesAvailable } }
    var totalVulnerabilities: Int { environments.reduce(0) { $0 + ($1.actionableVulnerabilities ?? 0) } }
    var onlineEnvironments: Int { environments.count(where: \.online) }

    static func signedOut(generatedAt: Date) -> WidgetSnapshot {
        WidgetSnapshot(
            generatedAt: generatedAt,
            serverConfigured: false,
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
}
