import Arcane
import Foundation

struct BackupRequestScope {
    let generation: Int
    let environmentID: EnvironmentID
    init(_ manager: ArcaneClientManager) {
        generation = manager.clientGeneration
        environmentID = manager.activeEnvironmentID
    }
    func check(_ manager: ArcaneClientManager) throws {
        try Task.checkCancellation()
        guard generation == manager.clientGeneration, environmentID == manager.activeEnvironmentID else { throw CancellationError() }
    }
}
