import Arcane
import SwiftUI

extension View {
    func fleetMaintenanceConfirmation(action: Binding<FleetMaintenanceAction?>, environments: [Arcane.Environment])
        -> some View
    {
        modifier(FleetMaintenanceConfirmation(action: action, environments: environments))
    }
}

private struct FleetMaintenanceConfirmation: ViewModifier {
    @Binding var action: FleetMaintenanceAction?
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
                            await FleetOperationStore.shared.performMaintenance(
                                action, environments: environments, manager: manager)
                        }
                    }
                ],
                dismissOnConfirm: false
            )
        }
    }
}
