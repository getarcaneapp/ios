import SwiftUI

struct FormTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default
    var textContentType: UITextContentType?
    var autocapitalization: TextInputAutocapitalization = .sentences
    var autocorrectionDisabled = false
    var axis: Axis = .horizontal
    var lineLimit: ClosedRange<Int>?
    var monospaced = false
    var helper: String?
    var disabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text, axis: axis)
                .keyboardType(keyboardType)
                .textContentType(textContentType)
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled(autocorrectionDisabled)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .disabled(disabled)
                .modifier(FormTextLineLimitModifier(lineLimit: lineLimit))
            if let helper, !helper.isEmpty {
                Text(helper)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct FormSecureField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var textContentType: UITextContentType?
    var helper: String?
    var disabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            SecureField(placeholder, text: $text)
                .textContentType(textContentType)
                .disabled(disabled)
            if let helper, !helper.isEmpty {
                Text(helper)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct FormValueRow: View {
    let title: String
    let value: String
    var helper: String?
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .foregroundStyle(.primary)
            if let helper, !helper.isEmpty {
                Text(helper)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct FormPicker<SelectionValue: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: SelectionValue
    var helper: String?
    let content: () -> Content

    init(
        title: String,
        selection: Binding<SelectionValue>,
        helper: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        _selection = selection
        self.helper = helper
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(title)
                    .foregroundStyle(.primary)

                Spacer(minLength: 12)

                Picker(title, selection: $selection) {
                    content()
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel(title)
            }
            if let helper, !helper.isEmpty {
                Text(helper)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct FormTextLineLimitModifier: ViewModifier {
    let lineLimit: ClosedRange<Int>?

    func body(content: Content) -> some View {
        if let lineLimit {
            content.lineLimit(lineLimit)
        } else {
            content
        }
    }
}
