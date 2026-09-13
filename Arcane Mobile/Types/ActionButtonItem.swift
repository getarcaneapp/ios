import SwiftUI

struct ActionButtonItem: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let tint: Color
    let role: ButtonRole?
    let confirmationMessage: String?
    let action: () -> Void

    init(
        id: String,
        title: String,
        systemImage: String,
        tint: Color,
        role: ButtonRole? = nil,
        confirmationMessage: String? = nil,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.role = role
        self.confirmationMessage = confirmationMessage
        self.action = action
    }
}

