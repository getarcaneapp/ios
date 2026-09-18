//
//  DeployActivityAttributes.swift
//  Shared between the app and the widget extension.
//
//  Attributes for the deploy/redeploy/pull/build Live Activity. Kept SDK-free
//  (the action kind travels as a raw string) so the ContentState stays a
//  trivially-Codable payload. `nonisolated` because both targets build with
//  MainActor default isolation and ActivityKit encodes these off-actor.
//

import ActivityKit
import Foundation

nonisolated struct DeployActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        /// Human-readable phase, e.g. "Pulling", "Starting", "Complete".
        var phase: String
        /// 0…1 when the operation has measurable progress (image pulls);
        /// nil renders an indeterminate treatment.
        var progress: Double?
        var state: RunState
        /// Optional short latest output line for the expanded presentations.
        var detail: String?
    }

    nonisolated enum RunState: String, Codable, Hashable {
        case running, success, failure
    }

    /// Project or container display name.
    var targetName: String
    /// Raw `DeploymentActionKind` value ("up", "redeploy", "pull", "build",
    /// "containerRedeploy", "containerUpdate") — mapped to presentation below.
    var actionKind: String
    var environmentName: String
}

// MARK: - Presentation mapping (shared by app + widget UI)

extension DeployActivityAttributes {
    var verb: String {
        switch actionKind {
        case "up": "Deploy"
        case "pull": "Pull Images"
        case "build": "Build Images"
        case "imagePull": "Pull"
        case "containerUpdate", "auto_update": "Update"
        case "containerRedeploy": "Redeploy"
        case "system_prune": "Prune"
        case "vulnerability_scan": "Scan"
        case "job_run": "Job"
        default: "Activity"
        }
    }

    var symbolName: String {
        switch actionKind {
        case "up": "shippingbox.fill"
        case "pull", "imagePull": "arrow.down"
        case "build": "hammer.fill"
        case "containerUpdate", "auto_update": "arrow.up.circle.fill"
        case "containerRedeploy": "arrow.triangle.2.circlepath"
        case "system_prune": "trash"
        case "vulnerability_scan": "shield.fill"
        case "job_run": "clock.badge"
        default: "gearshape.fill"
        }
    }

    /// Title shown in the Live Activity, mirroring the in-app sheet titles:
    /// name-scoped for deploy/redeploy, plain for pull/build.
    var title: String {
        switch actionKind {
        case "pull", "build": verb
        default: "\(verb) \(targetName)"
        }
    }
}
