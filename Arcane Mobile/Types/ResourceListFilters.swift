import Arcane
import Foundation

enum ContainerStateFilter: String, CaseIterable {
    case all = "All"
    case running = "Running"
    case stopped = "Stopped"
}

enum ProjectStatusFilter: String, CaseIterable {
    case all = "All"
    case running = "Running"
    case stopped = "Stopped"
    case partial = "Partial"
}

enum ImageTagsFilter: String, CaseIterable {
    case all = "All"
    case tagged = "Tagged"
    case untagged = "Untagged"
}

enum NetworkTypeFilter: String, CaseIterable {
    case all = "All"
    case standard = "Standard"
    case internalOnly = "Internal"
}

enum VolumeScopeFilter: String, CaseIterable {
    case all = "All"
    case local = "Local"
    case global = "Global"
}
