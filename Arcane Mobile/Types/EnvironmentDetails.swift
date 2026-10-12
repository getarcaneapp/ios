import Arcane
import Foundation

/// Adds tunnel measurements absent from the SDK without duplicating its environment model.
nonisolated struct EnvironmentDetails: Decodable, Sendable {
    let environment: Arcane.Environment
    let edgeDataPlane: String?
    let edgeRoundTripMs: Double?
    let edgeOpenStreams: Int?

    private enum CodingKeys: String, CodingKey {
        case edgeDataPlane, edgeRoundTripMs, edgeOpenStreams
    }

    init(from decoder: Decoder) throws {
        environment = try Arcane.Environment(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        edgeDataPlane = try values.decodeIfPresent(String.self, forKey: .edgeDataPlane)
        edgeRoundTripMs = try values.decodeIfPresent(Double.self, forKey: .edgeRoundTripMs)
        edgeOpenStreams = try values.decodeIfPresent(Int.self, forKey: .edgeOpenStreams)
    }
}

enum EnvironmentDetailSection: String, CaseIterable, Identifiable {
    case info = "Info"
    case connection = "Connection"
    case features = "Features"
    case storage = "Storage"
    case docker = "Docker"
    case security = "Security"
    case automations = "Automations"
    case gitOps = "GitOps"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .info: "info.circle"
        case .connection: "network"
        case .features: "switch.2"
        case .storage: "externaldrive"
        case .docker: "shippingbox.fill"
        case .security: "shield.lefthalf.filled"
        case .automations: "calendar.badge.clock"
        case .gitOps: "arrow.triangle.merge"
        }
    }

    /// Tabs that edit the environment's settings.
    var isSettings: Bool {
        switch self {
        case .features, .storage, .docker, .security, .automations: true
        case .info, .connection, .gitOps: false
        }
    }
}
