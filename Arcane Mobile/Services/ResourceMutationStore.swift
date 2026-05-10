import Arcane
import Observation

@Observable
final class ResourceMutationStore {
    static let shared = ResourceMutationStore()

    enum Kind: String {
        case containers
        case images
        case projects
        case volumes
        case networks
        case environments
    }

    // Reading this from `version(...)` establishes the @Observable dependency
    // so resource lists can react when a mutation elsewhere invalidates them.
    private(set) var versions: [String: Int] = [:]

    private init() {}

    func version(kind: Kind, envID: EnvironmentID? = nil) -> Int {
        versions[versionKey(kind: kind, envID: envID), default: 0]
    }

    func markChanged(kind: Kind, envID: EnvironmentID? = nil) {
        let key = versionKey(kind: kind, envID: envID)
        versions[key, default: 0] &+= 1
    }

    private func versionKey(kind: Kind, envID: EnvironmentID?) -> String {
        "\(kind.rawValue)::\(envID?.rawValue ?? "_global_")"
    }
}
