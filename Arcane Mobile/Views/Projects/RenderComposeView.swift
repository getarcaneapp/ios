import SwiftUI
import Arcane

struct RenderComposeView: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let initialCompose: String
    let initialEnv: String
    let environmentID: EnvironmentID
    let onApply: (String) -> Void

    @State private var values: [String: String] = [:]
    @State private var defaults: [String: String] = [:]
    @State private var variableOrder: [String] = []
    @State private var resolved: String = ""
    @State private var showPreview = false

    var body: some View {
        NavigationStack {
            Group {
                if variableOrder.isEmpty {
                    ContentUnavailableView(
                        "No Variables",
                        systemImage: "checkmark.seal",
                        description: Text("This compose file has no ${VAR} placeholders to resolve.")
                    )
                } else if showPreview {
                    previewPane
                } else {
                    formPane
                }
            }
            .navigationTitle(showPreview ? "Resolved YAML" : "Resolve Variables")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if showPreview {
                        Button("Edit") { showPreview = false }
                    } else if !variableOrder.isEmpty {
                        Button("Preview") {
                            resolved = substitute(in: initialCompose)
                            showPreview = true
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Resolved") {
                        let final = substitute(in: initialCompose)
                        onApply(final)
                        dismiss()
                    }
                    .disabled(variableOrder.isEmpty)
                }
            }
            .task { scanForVariables() }
        }
    }

    private var formPane: some View {
        Form {
            Section {
                Text("Fill values for the placeholders found in this compose file. Empty values fall back to the default (if any).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Variables") {
                ForEach(variableOrder, id: \.self) { key in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(key)
                                .font(.system(.subheadline, design: .monospaced))
                                .bold()
                            Spacer()
                            if let def = defaults[key], !def.isEmpty {
                                Text("default: \(def)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        TextField(defaults[key] ?? "value", text: Binding(
                            get: { values[key] ?? "" },
                            set: { values[key] = $0 }
                        ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var previewPane: some View {
        ScrollView {
            Text(resolved)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
    }

    // MARK: - Scanning + substitution

    private func scanForVariables() {
        let envDefaults = parseEnv(initialEnv)
        let pattern = #"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::?[-?]([^}]*))?\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let ns = initialCompose as NSString
        let matches = regex.matches(in: initialCompose, range: NSRange(location: 0, length: ns.length))

        var seen = Set<String>()
        var order: [String] = []
        var defs: [String: String] = [:]

        for match in matches {
            let nameRange = match.range(at: 1)
            guard nameRange.location != NSNotFound else { continue }
            let name = ns.substring(with: nameRange)
            if seen.insert(name).inserted {
                order.append(name)
            }
            // Inline default like ${VAR:-fallback}
            if defs[name] == nil, match.numberOfRanges >= 3 {
                let defaultRange = match.range(at: 2)
                if defaultRange.location != NSNotFound {
                    defs[name] = ns.substring(with: defaultRange)
                }
            }
            // .env default
            if defs[name] == nil, let envValue = envDefaults[name] {
                defs[name] = envValue
            }
        }

        variableOrder = order
        defaults = defs
        // Pre-populate values with the defaults so users see what would be substituted
        for name in order where values[name] == nil {
            values[name] = defs[name] ?? ""
        }
    }

    private func parseEnv(_ contents: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in contents.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    private func substitute(in source: String) -> String {
        let pattern = #"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::?[-?][^}]*)?\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        let ns = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: ns.length))

        var output = source
        for match in matches.reversed() {
            let fullRange = match.range(at: 0)
            let nameRange = match.range(at: 1)
            guard nameRange.location != NSNotFound else { continue }
            let name = ns.substring(with: nameRange)
            let value = (values[name]?.isEmpty == false ? values[name] : defaults[name]) ?? ""
            if let swiftRange = Range(fullRange, in: output) {
                output.replaceSubrange(swiftRange, with: value)
            }
        }
        return output
    }
}
