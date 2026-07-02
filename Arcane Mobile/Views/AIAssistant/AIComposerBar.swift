import SwiftUI
import UIKit

/// Composer bar rendered at the bottom of `AIChatView`.
/// Uses pure local @State for the draft so that typing never touches
/// service.inputDraft and never triggers a re-render of AIChatView.
/// Re-renders of AIChatView were the root cause of repeated focus loss
/// (SwiftUI resets @FocusState when the parent re-evaluates its body).
@available(iOS 26, *)
struct AIComposerBar: View {
    let isResponding: Bool
    let isAvailable: Bool
    let onSend: (String) -> Void
    let onStop: () -> Void

    @State private var draft = ""

    private var pillShape: RoundedRectangle { .rect(cornerRadius: Radius.card, style: .continuous) }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isResponding
            && isAvailable
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.circle")
                    .font(.caption2)
                Text("Assistant uses AI and can make mistakes.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .center)

            HStack(alignment: .bottom, spacing: 6) {
                // UIKit-backed field: SwiftUI's TextField has repeatedly lost its
                // input session inside the assistant's glass/sheet hosting (caret
                // visible, keystrokes silently dropped — recurred across iOS 26
                // betas). A UITextField owns its first responder and text storage,
                // so SwiftUI re-hosting can't detach it.
                ComposerTextField(text: $draft, placeholder: "Message") { send() }
                    .frame(maxWidth: .infinity)
                    .padding(.leading, 16)
                    .padding(.vertical, 10)

                Button {
                    if isResponding { onStop() } else { send() }
                } label: {
                    Image(systemName: isResponding ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(buttonTint)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .disabled(!isResponding && !canSend)
                .animation(Motion.state, value: canSend)
                .padding(.trailing, 5)
                .padding(.bottom, 4)
                .accessibilityLabel(isResponding ? "Stop" : "Send")
            }
            .background(.regularMaterial, in: pillShape)
            .overlay {
                pillShape.strokeBorder(.primary.opacity(0.07), lineWidth: 0.5)
            }
            .borderBeam(
                border: .purple,
                beam: [.indigo, .purple, .pink],
                beamBlur: 12,
                cornerRadius: Radius.card,
                isEnabled: isResponding
            )
            .animation(Motion.state, value: isResponding)
            .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 6)
        }
    }

    private func send() {
        guard canSend else { return }
        onSend(draft)
        draft = ""
    }

    private var buttonTint: Color {
        if isResponding { return .secondary }
        return canSend ? .accentColor : Color(.tertiaryLabel)
    }
}

/// See the comment at the `ComposerTextField` use site: UIKit text field whose
/// first responder survives SwiftUI re-hosting. Keep delegate work here minimal —
/// text changes flow out through the binding only.
@available(iOS 26, *)
private struct ComposerTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.returnKeyType = .send
        field.backgroundColor = .clear
        field.borderStyle = .none
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        // Only push the binding into UIKit when it actually differs (e.g. send()
        // clearing the draft) — unconditional writes move the caret mid-edit.
        if field.text != text { field.text = text }
    }

    // Single-line height: without this the representable accepts whatever height
    // the layout proposes and the composer pill balloons to fill the screen.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        let intrinsic = uiView.intrinsicContentSize
        let width = (proposal.width?.isFinite == true) ? proposal.width! : intrinsic.width
        return CGSize(width: width, height: intrinsic.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ComposerTextField
        init(parent: ComposerTextField) { self.parent = parent }

        @objc func editingChanged(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}
