import Foundation

enum BackupOperation: String, Identifiable {
    case restore, delete
    var id: String { rawValue }
}
