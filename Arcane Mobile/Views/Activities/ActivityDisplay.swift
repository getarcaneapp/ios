import SwiftUI
import Arcane

nonisolated enum ActivityStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case active
    case queued
    case running
    case failed
    case completed
    case cancelled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .active: return "Active"
        case .queued: return "Queued"
        case .running: return "Running"
        case .failed: return "Failed"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "tray.full"
        case .active: return "bolt.circle"
        case .queued: return "clock"
        case .running: return "play.circle"
        case .failed: return "xmark.octagon"
        case .completed: return "checkmark.circle"
        case .cancelled: return "slash.circle"
        }
    }

    func matches(_ activity: Activity) -> Bool {
        switch self {
        case .all:
            return true
        case .active:
            return activity.status == .queued || activity.status == .running
        case .queued:
            return activity.status == .queued
        case .running:
            return activity.status == .running
        case .failed:
            return activity.status == .failed
        case .completed:
            return activity.status == .success
        case .cancelled:
            return activity.status == .cancelled
        }
    }
}

extension Activity {
    nonisolated var isCancellable: Bool {
        status == .queued || status == .running
    }

    nonisolated var displayTitle: String {
        let name = resourceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? type.displayName : name
    }

    nonisolated var subtitle: String {
        let resource = resourceType?.activityDisplayName ?? type.displayName
        if step.isEmpty { return resource }
        return "\(resource) - \(step)"
    }

    nonisolated var sourceEnvironmentKey: String {
        let trimmedSource = sourceEnvironmentID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedSource.isEmpty { return trimmedSource }
        let trimmedEnvironment = environmentID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedEnvironment.isEmpty ? EnvironmentID.localDocker.rawValue : trimmedEnvironment
    }

    nonisolated var sortTime: Date {
        updatedAt ?? endedAt ?? startedAt
    }

    var statusTint: Color {
        status.activityTint
    }
}

extension ActivityStatus {
    var activityTint: Color {
        switch self {
        case .running: return .blue
        case .queued: return .orange
        case .success: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        case .unknown: return .secondary
        }
    }

}

extension Activity {
    var typeIcon: String {
        switch type {
        case let raw where raw.rawValue.hasPrefix("project_"):
            return "square.stack.3d.up.fill"
        case let raw where raw.rawValue.hasPrefix("image_"):
            return "photo.stack.fill"
        case let raw where raw.rawValue.hasPrefix("container_"):
            return "cube.box.fill"
        case .vulnerabilityScan:
            return "shield.lefthalf.filled"
        case .systemPrune:
            return "trash.circle.fill"
        case .autoUpdate:
            return "arrow.triangle.2.circlepath"
        default:
            return "clock.arrow.circlepath"
        }
    }
}

extension ActivityType {
    nonisolated var displayName: String {
        rawValue.activityDisplayName
    }
}

extension ActivityMessageLevel {
    var icon: String {
        switch self {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .success: return "checkmark.circle.fill"
        case .info, .unknown: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .error: return .red
        case .warning: return .orange
        case .success: return .green
        case .info, .unknown: return .secondary
        }
    }
}

extension ActivityStartedBy {
    nonisolated var displayLabel: String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? username : trimmed
    }
}

extension String {
    nonisolated var activityDisplayName: String {
        split(separator: "_")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}
