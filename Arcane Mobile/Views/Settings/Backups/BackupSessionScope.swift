import SwiftUI

struct BackupSessionScope: ViewModifier {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    func body(content: Content) -> some View {
        content
            .onChange(of: manager.clientGeneration) { _, _ in dismiss() }
            .onChange(of: manager.activeEnvironmentID) { _, _ in dismiss() }
    }
}
