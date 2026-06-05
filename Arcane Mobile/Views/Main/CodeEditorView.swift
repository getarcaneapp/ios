import SwiftUI
import UIKit

enum EditorLanguage: Equatable {
    case yaml
    case env
}

// MARK: - Editor View

struct CodeEditorView: UIViewRepresentable {
    @Binding var text: String
    var language: EditorLanguage = .yaml

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
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 32, right: 8)
        tv.inputAccessoryView = makeToolbar(coordinator: context.coordinator)
        context.coordinator.textView = tv
        applyHighlighting(to: tv, text: text)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let coord = context.coordinator
        guard tv.text != text || coord.appliedLanguage != language else { return }
        let sel = tv.selectedRange
        applyHighlighting(to: tv, text: text)
        coord.appliedLanguage = language
        let safeLoc = min(sel.location, (tv.text ?? "").utf16.count)
        tv.selectedRange = NSRange(location: safeLoc, length: 0)
    }

    private func applyHighlighting(to tv: UITextView, text: String) {
        let font = UIFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
        tv.attributedText = language == .yaml
            ? YAMLHighlighter.highlight(text, font: font)
            : EnvHighlighter.highlight(text, font: font)
    }

    private func makeToolbar(coordinator: Coordinator) -> UIToolbar {
        let tb = UIToolbar()
        tb.sizeToFit()
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        func btn(_ title: String, action: Selector) -> UIBarButtonItem {
            UIBarButtonItem(title: title, style: .plain, target: coordinator, action: action)
        }
        // `.prominent` bar-button style is iOS 26+; `.done` (bold title) is the
        // closest equivalent on iOS 18.
        let doneStyle: UIBarButtonItem.Style
        if #available(iOS 26, *) {
            doneStyle = .prominent
        } else {
            doneStyle = .done
        }
        if language == .yaml {
            tb.items = [
                btn("⇥", action: #selector(Coordinator.indent)),
                btn("⇤", action: #selector(Coordinator.dedent)),
                flex,
                btn(":", action: #selector(Coordinator.colon)),
                btn("-", action: #selector(Coordinator.dash)),
                btn("|", action: #selector(Coordinator.pipe)),
                btn("\"\"", action: #selector(Coordinator.quotes)),
                flex,
                UIBarButtonItem(title: "Done", style: doneStyle, target: coordinator, action: #selector(Coordinator.done)),
            ]
        } else {
            tb.items = [
                btn("=", action: #selector(Coordinator.equals)),
                btn("\"\"", action: #selector(Coordinator.quotes)),
                flex,
                UIBarButtonItem(title: "Done", style: doneStyle, target: coordinator, action: #selector(Coordinator.done)),
            ]
        }
        return tb
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditorView
        weak var textView: UITextView?
        var appliedLanguage: EditorLanguage

        init(_ parent: CodeEditorView) {
            self.parent = parent
            self.appliedLanguage = parent.language
        }

        func textViewDidChange(_ tv: UITextView) {
            let text = tv.text ?? ""
            parent.text = text
            let font = UIFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
            let attr = parent.language == .yaml
                ? YAMLHighlighter.highlight(text, font: font)
                : EnvHighlighter.highlight(text, font: font)
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

        @objc func indent() { textView?.insertText("  ") }

        @objc func dedent() {
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

        @objc func colon() { textView?.insertText(": ") }

        @objc func dash() {
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

        @objc func pipe() { textView?.insertText(" |") }

        @objc func quotes() {
            textView?.insertText("\"\"")
            if let tv = textView {
                tv.selectedRange = NSRange(location: tv.selectedRange.location - 1, length: 0)
            }
        }

        @objc func equals() { textView?.insertText("=") }

        @objc func done() { textView?.resignFirstResponder() }
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

// MARK: - Helpers

private func adaptive(dark d: (CGFloat, CGFloat, CGFloat), light l: (CGFloat, CGFloat, CGFloat)) -> UIColor {
    UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: d.0, green: d.1, blue: d.2, alpha: 1)
        : UIColor(red: l.0, green: l.1, blue: l.2, alpha: 1)
    }
}
