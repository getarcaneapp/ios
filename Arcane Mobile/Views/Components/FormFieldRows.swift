import SwiftUI

/// How a form field lays out its title and value.
///
/// - `.inline`: Apple-Settings style — title left, value right-aligned on one
///   ~44pt row. The default for short single-line values.
/// - `.stacked`: caption title above a full-width field. Reserved for long-form
///   values (URLs, paths, textareas) that need the horizontal room.
/// - `.automatic`: resolves to `.stacked` for vertical/multi-line/URL fields and
///   `.inline` otherwise, so most call sites need no `layout:` argument.
enum FormFieldLayout {
    case automatic
    case inline
    case stacked
}

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
    var layout: FormFieldLayout = .automatic

    // Reflects `.disabled(...)` applied by an ancestor (e.g. a whole Section):
    // TextField text isn't grayed by `.disabled` alone, so we dim the value.
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool

    /// Long-form fields (multi-line, or URLs that tend to overflow) stack; short
    /// single-line fields sit inline.
    private var resolvedLayout: FormFieldLayout {
        switch layout {
        case .automatic:
            if axis == .vertical || lineLimit != nil || keyboardType == .URL {
                return .stacked
            }
            return .inline
        case .inline, .stacked:
            return layout
        }
    }

    private var valueColor: Color {
        (isEnabled && !disabled) ? .primary : .secondary
    }

    var body: some View {
        switch resolvedLayout {
        case .stacked, .automatic:
            stackedBody
        case .inline:
            inlineBody
        }
    }

    private var inlineBody: some View {
        VStack(alignment: .trailing, spacing: 4) {
            LabeledContent(title) {
                TextField(placeholder, text: $text)
                    .multilineTextAlignment(.trailing)
                    // LabeledContent dims its content to secondary; editable
                    // values must read primary (except when disabled).
                    .foregroundStyle(valueColor)
                    .focused($isFocused)
                    .keyboardType(keyboardType)
                    .textContentType(textContentType)
                    .textInputAutocapitalization(autocapitalization)
                    .autocorrectionDisabled(autocorrectionDisabled)
                    .font(monospaced ? .system(.body, design: .monospaced) : .body)
                    .disabled(disabled)
            }
            helperCaption
        }
        .contentShape(Rectangle())
        // Whole-row tap focuses the field — the value area is small when empty.
        .onTapGesture { isFocused = true }
    }

    private var stackedBody: some View {
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
                .foregroundStyle(valueColor)
                .disabled(disabled)
                .modifier(FormTextLineLimitModifier(lineLimit: lineLimit))
            helperCaption
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var helperCaption: some View {
        if let helper, !helper.isEmpty {
            Text(helper)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct FormSecureField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var textContentType: UITextContentType?
    var helper: String?
    var disabled = false

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool

    private var valueColor: Color {
        (isEnabled && !disabled) ? .primary : .secondary
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            LabeledContent(title) {
                SecureField(placeholder, text: $text)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(valueColor)
                    .focused($isFocused)
                    .textContentType(textContentType)
                    .disabled(disabled)
            }
            if let helper, !helper.isEmpty {
                Text(helper)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
    }
}

/// Inline numeric row: a right-aligned number field plus a −/+ stepper for
/// nudging. Typing stays available for large values; the stepper clamps to the
/// field's `minValue`/`maxValue` (the floor defaults to 0 — these settings are
/// all non-negative). String-backed to match the flat settings store.
struct FormNumberField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var minValue: Int?
    var maxValue: Int?
    var step: Int = 1
    var helper: String?
    var disabled = false

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool

    private var floor: Int { minValue ?? 0 }

    private var currentValue: Int {
        Int(text.trimmingCharacters(in: .whitespaces)) ?? floor
    }

    private var valueColor: Color {
        (isEnabled && !disabled) ? .primary : .secondary
    }

    private func adjust(by delta: Int) {
        var next = currentValue + delta
        next = Swift.max(next, floor)
        if let maxValue { next = Swift.min(next, maxValue) }
        text = String(next)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            LabeledContent(title) {
                HStack(spacing: 8) {
                    TextField(placeholder, text: $text)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                        .foregroundStyle(valueColor)
                        .focused($isFocused)
                        .disabled(disabled)
                    Stepper {
                        EmptyView()
                    } onIncrement: {
                        adjust(by: step)
                    } onDecrement: {
                        adjust(by: -step)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(disabled)
                    .accessibilityLabel(title)
                }
            }
            if let helper, !helper.isEmpty {
                Text(helper)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct FormValueRow: View {
    let title: String
    let value: String
    var helper: String?
    var monospaced = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            LabeledContent(title) {
                Text(value)
                    .font(monospaced ? .system(.body, design: .monospaced) : .body)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            if let helper, !helper.isEmpty {
                Text(helper)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
        // A bare menu Picker in a Form already renders title-left / value+chevron
        // -right, matching Toggle/TextField rows. Only wrap it when a helper caption
        // is needed below.
        if let helper, !helper.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                picker
                Text(helper)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            picker
        }
    }

    private var picker: some View {
        Picker(title, selection: $selection) {
            content()
        }
        .pickerStyle(.menu)
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
