import SwiftUI

/// Inline card shown when the assistant stages a mutation. Glass-styled with
/// an icon, description, and Cancel / Confirm. Nothing runs until confirmed;
/// destructive actions are tinted red and routed through the app's extra-friction card.
struct AIActionConfirmationCard: View {
    let action: AIPendingAction
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var accent: Color { action.isDestructive ? .red : .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: action.isDestructive ? "exclamationmark.triangle.fill" : "sparkles")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(action.confirmationTitle)
                        .font(.subheadline.weight(.semibold))
                    Text("Runs only when you confirm.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button("Cancel", action: onCancel)
                    .glassButtonStyleCompat()
                Spacer(minLength: 0)
                Button(action.actionTitle) {
                    HapticsManager.light()
                    onConfirm()
                }
                .glassProminentButtonStyleCompat()
                .tint(accent)
            }
            .controlSize(.regular)
            .font(.subheadline.weight(.medium))
        }
        .padding(16)
        .glassEffectCompat(in: .rect(cornerRadius: 20, style: .continuous))
    }
}
