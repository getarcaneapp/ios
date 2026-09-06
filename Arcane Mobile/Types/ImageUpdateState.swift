import Foundation
import Arcane

nonisolated enum ImageUpdateState: Equatable {
    case unknown
    case upToDate
    case hasUpdate
    case error(String)

    init(info: ImageUpdateInfo?) {
        guard let info else { self = .unknown; return }
        if info.hasUpdate { self = .hasUpdate }
        else if !info.error.isEmpty { self = .error(info.error) }
        else if info.hasCheckResult || info.checkTime != nil { self = .upToDate }
        else { self = .unknown }
    }

    static func resolve(inline: ImageUpdateInfo?, references: [String], results: [String: ImageUpdateResponse]) -> Self {
        let tags = Set(references.filter { $0 != "<none>:<none>" })
        let checks = tags.sorted().compactMap { results[$0] }
        guard !checks.isEmpty else { return .init(info: inline) }
        if checks.contains(where: \.hasUpdate) { return .hasUpdate }
        if let error = checks.compactMap(\.error).first(where: { !$0.isEmpty }) { return .error(error) }
        guard checks.count == tags.count else { return .unknown }
        return .upToDate
    }

    var accessibilityDescription: String {
        switch self {
        case .unknown: "Update status not checked"
        case .upToDate: "Up to date"
        case .hasUpdate: "Update available"
        case .error(let message): "Update check failed: \(message)"
        }
    }
}
