import Arcane
import Foundation

/// An environment a resource list loads from. `name` is set only for the
/// All Environments preview, where rows show which environment they belong to.
nonisolated struct ListEnvironment: Hashable, Sendable {
    let id: EnvironmentID
    let name: String?
}

/// A resource paired with the environment it came from. Resource lists keep
/// these instead of bare resources so rows and actions always target the
/// item's own environment, including when one list mixes every environment.
@dynamicMemberLookup
nonisolated struct EnvironmentItem<Value: Identifiable & Sendable>: Identifiable, Sendable where Value.ID == String {
    let environmentID: EnvironmentID
    /// Set only in All Environments lists.
    let environmentName: String?
    let value: Value

    init(_ value: Value, in environment: ListEnvironment) {
        self.value = value
        environmentID = environment.id
        environmentName = environment.name
    }

    /// Single-environment lists keep the resource's own ID; All Environments
    /// lists prefix it so the same image or volume name in two environments
    /// stays two rows.
    var id: String { environmentName == nil ? value.id : "\(environmentID.rawValue)/\(value.id)" }

    subscript<T>(dynamicMember keyPath: KeyPath<Value, T>) -> T { value[keyPath: keyPath] }
}

extension EnvironmentItem: Equatable where Value: Equatable {}
extension EnvironmentItem: Hashable where Value: Hashable {}
