import SwiftUI

extension View {
    func resourceActionsToolbar(
        primary: ActionButtonItem? = nil,
        secondary: [ActionButtonItem] = [],
        overflow: [ActionButtonItem] = [],
        runningItemID: String? = nil,
        isDisabled: Bool = false,
        resourceName: String? = nil,
        active: Bool = true
    ) -> some View {
        modifier(ResourceActionToolbarModifier(
            primary: primary,
            secondary: secondary,
            overflow: overflow,
            runningItemID: runningItemID,
            isDisabled: isDisabled,
            resourceName: resourceName,
            active: active
        ))
    }
}

private struct ResourceActionToolbarModifier: ViewModifier {
    let primary: ActionButtonItem?
    let secondary: [ActionButtonItem]
    let overflow: [ActionButtonItem]
    let runningItemID: String?
    let isDisabled: Bool
    let resourceName: String?
    let active: Bool

    @State private var pendingDestructive: ActionButtonItem?

    private var menuItems: [ActionButtonItem] {
        secondary + overflow
    }

    func body(content: Content) -> some View {
        content
            .toolbar {
                if active {
                    if let primary {
                        AppToolbarItem(placement: .topBarTrailing) {
                            primaryButton(primary)
                        }
                    }

                    if #available(iOS 26, *), primary != nil, !menuItems.isEmpty {
                        ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    }

                    if !menuItems.isEmpty {
                        AppToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                ForEach(menuItems) { item in
                                    Button(role: menuRole(item)) {
                                        handle(item)
                                    } label: {
                                        if menuRole(item) == .destructive {
                                            DestructiveLabel(text: item.title, systemImage: item.systemImage)
                                        } else {
                                            Label(item.title, systemImage: item.systemImage)
                                        }
                                    }
                                    .disabled(disabled(item))
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .accessibilityLabel("More actions")
                            .disabled(isDisabled)
                        }
                    }
                }
            }
            .deleteConfirmation(item: $pendingDestructive) { item in
                DeleteConfirmationConfig(
                    title: destructiveTitle(for: item),
                    message: item.confirmationMessage ?? defaultConfirmationMessage(for: item),
                    icon: item.systemImage,
                    actions: [DeleteConfirmationAction(title: item.title, action: item.action)]
                )
            }
    }

    private func primaryButton(_ item: ActionButtonItem) -> some View {
        Button {
            handle(item)
        } label: {
            if runningItemID == item.id {
                ProgressView()
            } else {
                Image(systemName: item.systemImage)
                    .foregroundStyle(item.role == .destructive ? .red : item.tint)
            }
        }
        .accessibilityLabel(item.title)
        .disabled(disabled(item))
    }

    private func handle(_ item: ActionButtonItem) {
        if item.role == .destructive {
            pendingDestructive = item
        } else {
            item.action()
        }
    }

    private func disabled(_ item: ActionButtonItem) -> Bool {
        if isDisabled { return true }
        if let runningItemID, runningItemID != item.id { return true }
        return false
    }

    private func menuRole(_ item: ActionButtonItem) -> ButtonRole? {
        if item.role == .destructive || item.tint == .red { return .destructive }
        return nil
    }

    private func destructiveTitle(for item: ActionButtonItem) -> String {
        guard let resourceName else { return "\(item.title)?" }
        return "\(item.title) \(resourceName)?"
    }

    private func defaultConfirmationMessage(for item: ActionButtonItem) -> String {
        guard let resourceName else {
            return "Are you sure you want to \(item.title.lowercased())?"
        }
        return "Are you sure you want to \(item.title.lowercased()) \(resourceName)?"
    }
}
