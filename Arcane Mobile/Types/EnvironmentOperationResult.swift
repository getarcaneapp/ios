import Foundation

struct EnvironmentOperationResult: Identifiable {
    let id: String
    let name: String
    var status = "Waiting"
    var failed = false
    var finished = false
}
