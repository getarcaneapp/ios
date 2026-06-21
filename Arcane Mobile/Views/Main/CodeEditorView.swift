import SwiftUI
import UIKit

enum EditorLanguage: Equatable {
    case yaml
    case env
    case plaintext
}

// MARK: - Editor View

struct CodeEditorView: UIViewRepresentable {
    @Binding var text: String
    var language: EditorLanguage = .yaml
    var readOnly = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartDashesType = .no
        tv.smartQuotesType = .no
        tv.smartInsertDeleteType = .no
        tv.spellCheckingType = .no
        tv.isEditable = !readOnly
        tv.isSelectable = true
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 32, right: 8)
        // Quick-keys bar styled like the system predictive bar: a UIInputView
        // (keyboard material) hosting a horizontally scrollable SwiftUI strip.
        // NOT a UIToolbar — on iOS 26 toolbar items render as floating glass
        // pills that collide with the keyboard's own controls.
        tv.inputAccessoryView = makeQuickKeysBar(coordinator: context.coordinator)
        context.coordinator.textView = tv
        applyHighlighting(to: tv, text: text)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let coord = context.coordinator
        tv.isEditable = !readOnly
        guard tv.text != text || coord.appliedLanguage != language else { return }
        let sel = tv.selectedRange
        applyHighlighting(to: tv, text: text)
        coord.appliedLanguage = language
        let safeLoc = min(sel.location, (tv.text ?? "").utf16.count)
        tv.selectedRange = NSRange(location: safeLoc, length: 0)
    }

    private func applyHighlighting(to tv: UITextView, text: String) {
        let font = UIFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
        tv.attributedText = highlight(text, language: language, font: font)
    }

    private func highlight(_ text: String, language: EditorLanguage, font: UIFont) -> NSAttributedString {
        switch language {
        case .yaml:
            return YAMLHighlighter.highlight(text, font: font)
        case .env:
            return EnvHighlighter.highlight(text, font: font)
        case .plaintext:
            return PlainTextHighlighter.highlight(text, font: font)
        }
    }

    // MARK: - Quick keys bar

    private func makeQuickKeysBar(coordinator: Coordinator) -> UIView {
        let host = UIHostingController(
            rootView: EditorQuickKeysBar(language: language, coordinator: coordinator)
        )
        host.view.backgroundColor = .clear
        // Retain the hosting controller — handing UIKit just the view would
        // deallocate it and break button actions.
        coordinator.quickKeysHost = host

        let bar = UIInputView(
            frame: CGRect(x: 0, y: 0, width: 0, height: 48),
            inputViewStyle: .keyboard
        )
        host.view.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: bar.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        return bar
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditorView
        weak var textView: UITextView?
        var appliedLanguage: EditorLanguage
        /// Retains the quick-keys bar's hosting controller (see makeQuickKeysBar).
        var quickKeysHost: UIHostingController<EditorQuickKeysBar>?

        init(_ parent: CodeEditorView) {
            self.parent = parent
            self.appliedLanguage = parent.language
        }

        func textViewDidChange(_ tv: UITextView) {
            let text = tv.text ?? ""
            parent.text = text
            let font = UIFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
            let attr = parent.highlight(text, language: parent.language, font: font)
            let sel = tv.selectedRange
            tv.attributedText = attr
            let safeLoc = min(sel.location, text.utf16.count)
            tv.selectedRange = NSRange(location: safeLoc, length: 0)
        }

        func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n", parent.language == .yaml else { return true }
            let ns = tv.text as NSString
            let lineStart = ns.lineRange(for: NSRange(location: range.location, length: 0)).location
            let line = ns.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
            let indent = String(line.prefix(while: { $0 == " " }))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let extra = (trimmed.hasSuffix(":") || trimmed == "-"
                || trimmed.hasSuffix("|-") || trimmed.hasSuffix("|")
                || trimmed.hasSuffix(">")) ? "  " : ""
            tv.insertText("\n" + indent + extra)
            return false
        }

        // MARK: Quick-key actions

        func indent() { textView?.insertText("  ") }

        func dedent() {
            guard let tv = textView else { return }
            let ns = tv.text as NSString
            let lr = ns.lineRange(for: tv.selectedRange)
            let line = ns.substring(with: lr)
            guard line.hasPrefix("  ") else { return }
            let newText = ns.replacingCharacters(in: lr, with: String(line.dropFirst(2)))
            let newLoc = max(tv.selectedRange.location - 2, lr.location)
            tv.text = newText
            parent.text = newText
            tv.selectedRange = NSRange(location: newLoc, length: 0)
            textViewDidChange(tv)
        }

        func colon() { textView?.insertText(": ") }

        func dash() {
            guard let tv = textView else { return }
            let ns = tv.text as NSString
            let lineRange = ns.lineRange(for: NSRange(location: tv.selectedRange.location, length: 0))
            let lineText = ns.substring(with: NSRange(location: lineRange.location, length: tv.selectedRange.location - lineRange.location))
            let indent = String(lineText.prefix(while: { $0 == " " }))
            if lineText.trimmingCharacters(in: .whitespaces).isEmpty {
                tv.insertText("- ")
            } else {
                tv.insertText("\n" + indent + "- ")
            }
        }

        func pipe() { textView?.insertText(" |") }

        func quotes() {
            textView?.insertText("\"\"")
            if let tv = textView {
                tv.selectedRange = NSRange(location: tv.selectedRange.location - 1, length: 0)
            }
        }

        func equals() { textView?.insertText("=") }

        func hash() { textView?.insertText("# ") }

        func dismissKeyboard() { textView?.resignFirstResponder() }
    }
}

// MARK: - Quick keys bar (SwiftUI)

/// Predictive-bar-style strip above the keyboard: capsule keys in a horizontal
/// scroller (so any number of keys stays usable), with a pinned dismiss button.
/// Hosted inside a `UIInputView` so it sits on keyboard material.
struct EditorQuickKeysBar: View {
    let language: EditorLanguage
    // Strong ref is fine: the bar lives and dies with the coordinator's text view.
    let coordinator: CodeEditorView.Coordinator

    private var keys: [(label: String, action: () -> Void)] {
        switch language {
        case .yaml:
            return [
                ("⇥", coordinator.indent),
                ("⇤", coordinator.dedent),
                (":", coordinator.colon),
                ("-", coordinator.dash),
                ("|", coordinator.pipe),
                ("\u{201C}\u{201D}", coordinator.quotes),
                ("#", coordinator.hash),
            ]
        case .env:
            return [
                ("=", coordinator.equals),
                ("\u{201C}\u{201D}", coordinator.quotes),
                ("#", coordinator.hash),
            ]
        case .plaintext:
            return [
                ("\u{201C}\u{201D}", coordinator.quotes),
                ("#", coordinator.hash),
            ]
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                        Button(action: key.action) {
                            Text(key.label)
                                .font(.callout.weight(.medium).monospaced())
                                .foregroundStyle(.primary)
                                .frame(minWidth: 44, minHeight: 34)
                                .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
            }

            Button {
                coordinator.dismissKeyboard()
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 34)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss Keyboard")
            .padding(.trailing, 8)
        }
        .frame(height: 48)
    }
}

// MARK: - YAML Syntax Highlighting

private enum YAMLHighlighter {
    static let keyColor     = adaptive(dark: (0.50, 0.82, 1.00), light: (0.05, 0.40, 0.78))
    static let commentColor = adaptive(dark: (0.47, 0.72, 0.47), light: (0.20, 0.55, 0.20))
    static let stringColor  = adaptive(dark: (0.98, 0.75, 0.50), light: (0.75, 0.35, 0.05))
    static let numberColor  = adaptive(dark: (0.82, 0.65, 1.00), light: (0.50, 0.20, 0.80))
    static let boolColor    = adaptive(dark: (1.00, 0.60, 0.60), light: (0.78, 0.10, 0.10))
    static let anchorColor  = adaptive(dark: (1.00, 0.87, 0.45), light: (0.70, 0.50, 0.00))

    // (pattern, captureGroup) — group 0 means use full match
    private static let rules: [(String, Int, UIColor)] = [
        (#"(?m)^(\s*)([\w\-\.\/]+)(?=\s*:)"#, 2, keyColor),
        (#"'[^'\n]*'"#,                         0, stringColor),
        (#"\"[^\"\n]*\""#,                      0, stringColor),
        (#"(?<=:\s)\d+\.?\d*\b"#,               0, numberColor),
        (#"(?<=:\s)\b(true|false|yes|no|null|~|True|False|Yes|No|Null)\b"#, 0, boolColor),
        (#"[&*][\w\-]+"#,                       0, anchorColor),
        (#"(?m)#.*$"#,                          0, commentColor),
    ]

    static func highlight(_ text: String, font: UIFont) -> NSAttributedString {
        let out = NSMutableAttributedString(string: text)
        let full = NSRange(text.startIndex..., in: text)
        out.addAttributes([.foregroundColor: UIColor.label, .font: font], range: full)
        for (pattern, group, color) in rules {
            guard let rx = try? NSRegularExpression(pattern: pattern) else { continue }
            for m in rx.matches(in: text, range: full) {
                let r = group > 0 && group < m.numberOfRanges ? m.range(at: group) : m.range
                if r.location != NSNotFound { out.addAttribute(.foregroundColor, value: color, range: r) }
            }
        }
        return out
    }
}

// MARK: - .env Syntax Highlighting

private enum EnvHighlighter {
    static let keyColor     = adaptive(dark: (0.50, 0.82, 1.00), light: (0.05, 0.40, 0.78))
    static let valueColor   = adaptive(dark: (0.98, 0.75, 0.50), light: (0.75, 0.35, 0.05))
    static let commentColor = adaptive(dark: (0.47, 0.72, 0.47), light: (0.20, 0.55, 0.20))

    private static let rules: [(String, UIColor)] = [
        (#"(?m)^[A-Z_][A-Z0-9_]*(?==)"#, keyColor),
        (#"(?m)(?<==).*$"#,               valueColor),
        (#"(?m)#.*$"#,                    commentColor),
    ]

    static func highlight(_ text: String, font: UIFont) -> NSAttributedString {
        let out = NSMutableAttributedString(string: text)
        let full = NSRange(text.startIndex..., in: text)
        out.addAttributes([.foregroundColor: UIColor.label, .font: font], range: full)
        for (pattern, color) in rules {
            guard let rx = try? NSRegularExpression(pattern: pattern) else { continue }
            for m in rx.matches(in: text, range: full) {
                out.addAttribute(.foregroundColor, value: color, range: m.range)
            }
        }
        return out
    }
}

// MARK: - Plain Text Highlighting

private enum PlainTextHighlighter {
    static func highlight(_ text: String, font: UIFont) -> NSAttributedString {
        let out = NSMutableAttributedString(string: text)
        let full = NSRange(text.startIndex..., in: text)
        out.addAttributes([.foregroundColor: UIColor.label, .font: font], range: full)
        return out
    }
}

// MARK: - Helpers

private func adaptive(dark d: (CGFloat, CGFloat, CGFloat), light l: (CGFloat, CGFloat, CGFloat)) -> UIColor {
    UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: d.0, green: d.1, blue: d.2, alpha: 1)
        : UIColor(red: l.0, green: l.1, blue: l.2, alpha: 1)
    }
}
