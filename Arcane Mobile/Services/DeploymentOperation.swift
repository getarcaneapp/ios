import SwiftUI
import Arcane

// MARK: - Action kind

enum DeploymentActionKind: String, Sendable {
    case up, redeploy, pull, build, containerRedeploy, imagePull, containerUpdate

    var verb: String {
        switch self {
        case .up: "Deploy"
        case .redeploy, .containerRedeploy: "Redeploy"
        case .pull: "Pull Images"
        case .build: "Build Images"
        case .imagePull: "Pull"
        case .containerUpdate: "Update"
        }
    }

    var systemImage: String {
        switch self {
        case .up: "shippingbox.fill"
        case .redeploy, .containerRedeploy: "arrow.triangle.2.circlepath"
        case .pull, .imagePull: "arrow.down"
        case .build: "hammer.fill"
        case .containerUpdate: "arrow.up.circle.fill"
        }
    }

    /// Kinds backed by plain request/response calls rather than an NDJSON
    /// stream — pill + Live Activity only, and the response is authoritative.
    var isRequestBacked: Bool {
        self == .containerRedeploy || self == .containerUpdate
    }
}

// MARK: - Operation model

@MainActor
@Observable
final class DeploymentOperation: Identifiable {
    struct UpdateTarget: Sendable, Hashable {
        let id: String
        let name: String
    }

    let id = UUID()
    let kind: DeploymentActionKind
    let envID: EnvironmentID
    let targetID: String
    let targetName: String
    let environmentName: String
    let updateTargets: [UpdateTarget]
    let deployOptions: DeployOptions?
    let startedAt = Date()

    var lines: [InstallStreamLine] = []
    var status: InstallStreamStatus = .running
    var currentPhase: String?
    var seenPhases: [String] = []
    var progressFraction: Double?
    var serverActivityID: String?
    var isServerSynced = false

    @ObservationIgnored internal var pullLayers: [String: (current: Int64, total: Int64)] = [:]
    @ObservationIgnored internal var syncedMessageIDs: Set<String> = []
    @ObservationIgnored internal var serverSyncCursor: Date?
    @ObservationIgnored internal var receivedTerminalSuccess = false
    @ObservationIgnored internal var activityLookupTargetID: String

    init(kind: DeploymentActionKind, envID: EnvironmentID, targetID: String,
         targetName: String, environmentName: String,
         updateTargets: [UpdateTarget] = [],
         deployOptions: DeployOptions? = nil) {
        self.kind = kind
        self.envID = envID
        self.targetID = targetID
        self.targetName = targetName
        self.environmentName = environmentName
        self.updateTargets = updateTargets
        self.deployOptions = deployOptions
        self.activityLookupTargetID = targetID
    }

    var title: String {
        switch kind {
        case .pull, .build: kind.verb
        default: "\(kind.verb) \(targetName)"
        }
    }
}
