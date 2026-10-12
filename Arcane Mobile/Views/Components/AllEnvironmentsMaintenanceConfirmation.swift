import Arcane
import SwiftUI

extension View {
    func allEnvironmentsMaintenanceConfirmation(
        action: Binding<AllEnvironmentsMaintenanceAction?>, environments: [Arcane.Environment]
    )
        -> some View
    {
        modifier(AllEnvironmentsMaintenanceConfirmation(action: action, environments: environments))
    }
}

private struct AllEnvironmentsMaintenanceConfirmation: ViewModifier {
    @Binding var action: AllEnvironmentsMaintenanceAction?
    let environments: [Arcane.Environment]
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager

    func body(content: Content) -> some View {
        content.deleteConfirmation(item: $action) { action in
            DeleteConfirmationConfig(
                title: action.title,
                message: action.explanation,
                icon: action.systemImage,
                actions: [
                    DeleteConfirmationAction(title: action.buttonTitle, role: nil, tint: .accentColor) {
                        Task {
                            await AllEnvironmentsOperationStore.shared.performMaintenance(
                                action, environments: environments, manager: manager)
                        }
                    }
                ],
                dismissOnConfirm: false
            )
        }
    }
}

/// Update All and Check All for an All Environments list's toolbar menu.
/// Pair with `allEnvironmentsMaintenanceConfirmation(action:environments:)`.
struct AllEnvironmentsMaintenanceButtons: View {
    @Binding var action: AllEnvironmentsMaintenanceAction?

    var body: some View {
        Group {
            Button(AllEnvironmentsMaintenanceAction.update.buttonTitle, systemImage: "arrow.triangle.2.circlepath") {
                action = .update
            }
            Button(AllEnvironmentsMaintenanceAction.checkImages.buttonTitle, systemImage: "arrow.clockwise") {
                action = .checkImages
            }
        }
        .disabled(AllEnvironmentsOperationStore.shared.isRunning)
    }
}
