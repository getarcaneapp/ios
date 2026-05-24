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

extension View {
    func actionToolbar(
        items: [ActionButtonItem],
        runningItemID: String? = nil,
        isDisabled: Bool = false,
        resourceName: String? = nil
    ) -> some View {
        modifier(ActionToolbarModifier(
            items: items,
            runningItemID: runningItemID,
            isDisabled: isDisabled,
            resourceName: resourceName
        ))
    }
}

private struct ActionToolbarModifier: ViewModifier {
    let items: [ActionButtonItem]
    let runningItemID: String?
    let isDisabled: Bool
    let resourceName: String?

    @State private var pendingDestructive: ActionButtonItem?

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !items.isEmpty {
                    bottomBar
                }
            }
            .confirmationDialog(
                destructiveDialogTitle,
                isPresented: Binding(
                    get: { pendingDestructive != nil },
                    set: { if !$0 { pendingDestructive = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDestructive
            ) { item in
                Button(item.title, role: .destructive) {
                    item.action()
                    pendingDestructive = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDestructive = nil
                }
            } message: { item in
                Text(item.confirmationMessage ?? defaultConfirmationMessage(for: item))
            }
    }

    private var bottomBar: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(items) { item in
                    actionButton(item)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func actionButton(_ item: ActionButtonItem) -> some View {
        let isRunning = runningItemID == item.id
        let buttonDisabled = isDisabled || (runningItemID != nil && !isRunning)

        VStack(spacing: 4) {
            Button {
                handleTap(item)
            } label: {
                ZStack {
                    if isRunning {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(item.tint)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    } else {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(item.tint)
                            .contentTransition(.symbolEffect(.replace))
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .frame(width: 50, height: 50)
                .contentShape(Circle())
                .motionAwareAnimation(.smooth(duration: 0.2), value: isRunning)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .shadow(color: Color.black.opacity(0.18), radius: 6, x: 0, y: 3)
            .disabled(buttonDisabled || isRunning)
            .opacity(buttonDisabled && !isRunning ? 0.45 : 1.0)
            .motionAwareAnimation(.smooth(duration: 0.2), value: buttonDisabled)

            Text(item.title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(.isButton)
    }

    private func handleTap(_ item: ActionButtonItem) {
        if item.role == .destructive {
            pendingDestructive = item
        } else {
            item.action()
        }
    }

    private var destructiveDialogTitle: String {
        guard let item = pendingDestructive else { return "" }
        if let name = resourceName {
            return "\(item.title) \(name)?"
        }
        return "\(item.title)?"
    }

    private func defaultConfirmationMessage(for item: ActionButtonItem) -> String {
        if let name = resourceName {
            return "Are you sure you want to \(item.title.lowercased()) \(name)?"
        }
        return "Are you sure you want to \(item.title.lowercased())?"
    }
}
