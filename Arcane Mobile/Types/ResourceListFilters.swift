import Arcane
import Foundation

enum ContainerStateFilter: String, CaseIterable {
    case all = "All"
    case running = "Running"
    case stopped = "Stopped"
}

/// Containers list sort. Name orders sort on device; CPU and memory sort on the
/// server through its shared stats collector, which returns a resource sample
/// for each running container.
enum ContainerListSort: String, CaseIterable, Identifiable {
    case nameAscending
    case nameDescending
    case cpuUsage
    case memoryUsage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nameAscending: return ListSortOrder.ascending.title
        case .nameDescending: return ListSortOrder.descending.title
        case .cpuUsage: return "CPU"
        case .memoryUsage: return "Memory"
        }
    }

    var systemImage: String {
        switch self {
        case .nameAscending: return ListSortOrder.ascending.systemImage
        case .nameDescending: return ListSortOrder.descending.systemImage
        case .cpuUsage: return "cpu"
        case .memoryUsage: return "memorychip"
        }
    }

    var resourceSort: ContainerResourceSort? {
        switch self {
        case .nameAscending, .nameDescending: return nil
        case .cpuUsage: return .cpuUsage
        case .memoryUsage: return .memoryUsage
        }
    }

    /// Resource sorts put the heaviest first and unsampled containers last,
    /// falling back to name so the order stays stable between refreshes.
    func areInIncreasingOrder(
        _ lhs: (name: String, sample: ContainerResourceSample?),
        _ rhs: (name: String, sample: ContainerResourceSample?)
    ) -> Bool {
        switch self {
        case .nameAscending:
            return ListSortOrder.ascending.areInIncreasingOrder(lhs.name, rhs.name)
        case .nameDescending:
            return ListSortOrder.descending.areInIncreasingOrder(lhs.name, rhs.name)
        case .cpuUsage, .memoryUsage:
            let lhsValue = lhs.sample.map(resourceValue)
            let rhsValue = rhs.sample.map(resourceValue)
            if lhsValue != rhsValue {
                guard let lhsValue else { return false }
                guard let rhsValue else { return true }
                return lhsValue > rhsValue
            }
            return ListSortOrder.ascending.areInIncreasingOrder(lhs.name, rhs.name)
        }
    }

    private func resourceValue(_ sample: ContainerResourceSample) -> Double {
        self == .memoryUsage ? Double(sample.memoryUsageBytes) : sample.cpuPercent
    }
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
