import SwiftUI

/// Shared floating actions for editable Settings screens.
///
/// Save remains pinned to the trailing edge. When the form becomes dirty,
/// Revert appears in a fixed horizontal lane so its Liquid Glass surface can
/// morph directly out of Save without animating either button's layout.
struct SettingsSaveBar: View {
    let hasChanges: Bool
    let isSaving: Bool
    var canSave = true
    var isInteractionDisabled = false
    var saveAccessibilityLabel = "Save"
    let onSave: () -> Void
    let onRevert: () -> Void

    @Namespace private var actionNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var saveDisabled: Bool {
        !hasChanges || !canSave || isSaving || isInteractionDisabled
    }

    var body: some View {
        GlassContainerCompat(spacing: 10) {
            ZStack {
                if hasChanges {
                    revertButton
                        .offset(x: -31)
                        .transition(revertTransition)
                }

                saveButton
                    .offset(x: 31)
            }
            .frame(width: 114, height: 52)
            .motionAwareAnimation(Motion.state, value: hasChanges)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    private var revertTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity,
            removal: .opacity.animation(
                Motion.reduced(Motion.earlyFade, reduceMotion: reduceMotion)
            )
        )
    }

    private var revertButton: some View {
        Button(action: onRevert) {
            Image(systemName: "arrow.uturn.backward")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .frame(width: 52, height: 52)
        .contentShape(.circle)
        .glassEffectCompat(tint: .orange, interactive: true, in: .circle)
        .glassEffectIDCompat("settings-revert", in: actionNamespace)
        .accessibilityLabel("Revert Changes")
        .disabled(isSaving || isInteractionDisabled)
        .opacity(isSaving || isInteractionDisabled ? 0.6 : 1)
    }

    private var saveButton: some View {
        Button(action: onSave) {
            ZStack {
                if isSaving {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "checkmark")
                        .font(.title.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: 52, height: 52)
        .contentShape(.circle)
        .glassChipCompat(tint: Color.accentColor, interactive: true, in: .circle)
        .glassEffectIDCompat("settings-save", in: actionNamespace)
        .accessibilityLabel(saveAccessibilityLabel)
        .disabled(saveDisabled)
        .opacity(saveDisabled && !isSaving ? 0.6 : 1)
    }
}

extension View {
    @ViewBuilder
    func settingsSaveBar(
        isPresented: Bool = true,
        hasChanges: Bool,
        isSaving: Bool,
        canSave: Bool = true,
        isInteractionDisabled: Bool = false,
        saveAccessibilityLabel: String = "Save",
        onSave: @escaping () -> Void,
        onRevert: @escaping () -> Void
    ) -> some View {
        if isPresented {
            safeAreaInset(edge: .bottom, spacing: 0) {
                SettingsSaveBar(
                    hasChanges: hasChanges,
                    isSaving: isSaving,
                    canSave: canSave,
                    isInteractionDisabled: isInteractionDisabled,
                    saveAccessibilityLabel: saveAccessibilityLabel,
                    onSave: onSave,
                    onRevert: onRevert
                )
            }
        } else {
            self
        }
    }
}
