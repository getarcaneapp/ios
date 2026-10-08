import Arcane
import Foundation

enum ContainerStateFilter: String, CaseIterable {
    case all = "All", running = "Running", stopped = "Stopped"
}

enum ProjectStatusFilter: String, CaseIterable {
    case all = "All", running = "Running", stopped = "Stopped", partial = "Partial"
}

enum ImageTagsFilter: String, CaseIterable {
    case all = "All", tagged = "Tagged", untagged = "Untagged"
}

enum NetworkTypeFilter: String, CaseIterable {
    case all = "All", standard = "Standard", internalOnly = "Internal"
}

enum VolumeScopeFilter: String, CaseIterable {
    case all = "All", local = "Local", global = "Global"
}

struct FleetResourceFilters {
    var environmentID: String?
    var state = ContainerStateFilter.all
    var status = ProjectStatusFilter.all
    var updates = ResourceUpdateFilter.all
    var tags = ImageTagsFilter.all
    var networkType = NetworkTypeFilter.all
    var scope = VolumeScopeFilter.all
    var showHidden = false
    var label = ""
    var severities = Set<VulnerabilitySeverity>()
    var image: String?
    var onlyFixAvailable = false

    var activeCount: Int {
        [environmentID != nil, state != .all, status != .all, updates != .all,
         tags != .all, networkType != .all, scope != .all, showHidden,
         !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
         !severities.isEmpty, image != nil, onlyFixAvailable].filter { $0 }.count
    }

    func matches(_ item: FleetResourceListItem) -> Bool {
        guard environmentID == nil || environmentID == item.bucket.id else { return false }
        switch item.resource {
        case .container(let value):
            let labelParts = label.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let matchesLabel = labelParts.isEmpty || labelParts[0].isEmpty || (labelParts.count == 1 ? value.labels[labelParts[0]] != nil : value.labels[labelParts[0]] == labelParts[1])
            return (showHidden || value.hidden != true) && matchesLabel
                && (state == .all || (state == .running ? value.isRunning : !value.isRunning))
                && updates.matches(hasUpdate: value.hasAvailableUpdate)
        case .project(let value):
            let raw = value.status.lowercased()
            let matchesStatus = status == .all || (status == .running && raw == "running")
                || (status == .stopped && ["stopped", "exited"].contains(raw))
                || (status == .partial && ["partial", "partially running"].contains(raw))
            return matchesStatus && updates.matches(hasUpdate: value.hasAvailableUpdate)
        case .image(let value):
            let tagged = value.repoTags.contains { $0 != "<none>:<none>" }
            return tags == .all || (tags == .tagged ? tagged : !tagged)
        case .network(let value):
            return networkType == .all || (networkType == .internalOnly ? value.isInternal : !value.isInternal)
        case .volume(let value):
            return scope == .all || (scope == .local ? value.scope.lowercased() == "local" : value.scope.lowercased() != "local")
        case .vulnerability(let value):
            return (severities.isEmpty || severities.contains { $0.rawValue.lowercased() == value.severity.rawValue.lowercased() })
                && (image == nil || image == value.imageName)
                && (!onlyFixAvailable || !(value.fixedVersion ?? "").isEmpty)
        default: return true
        }
    }
}
