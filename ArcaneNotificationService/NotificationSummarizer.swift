import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Writes a roll-up's body with Apple's on-device model (Apple Intelligence,
/// iOS 26+). Returns nil whenever the model isn't available, is slow, or
/// produces something unusable, so callers fall back to the plain list.
nonisolated enum NotificationSummarizer {
    /// Leaves room under the extension's ~30 s budget for delivery.
    static let timeout: Duration = .seconds(8)
    static let maximumLength = 200

    static func summarize(
        title: String, environmentName: String?, items: [NotificationRollup.Item]
    ) async -> String? {
        #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                return await summarizeOnDevice(title: title, environmentName: environmentName, items: items)
            }
        #endif
        return nil
    }

    /// Trims the model's reply and rejects anything that wouldn't read as a notification body.
    static func clean(_ raw: String) -> String? {
        let collapsed =
            raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”' "))
        guard !collapsed.isEmpty, collapsed.count <= maximumLength else { return nil }
        return collapsed
    }

    static func prompt(title: String, environmentName: String?, items: [NotificationRollup.Item]) -> String {
        var lines = ["Summary: \(title)"]
        if let environmentName, !environmentName.isEmpty { lines.append("Environment: \(environmentName)") }
        lines.append("Alerts, newest first:")
        lines += items.map { item in item.count > 1 ? "- \(item.label) (\(item.count))" : "- \(item.label)" }
        return lines.joined(separator: "\n")
    }

    #if canImport(FoundationModels)
        @available(iOS 26.0, *)
        private static func summarizeOnDevice(
            title: String, environmentName: String?, items: [NotificationRollup.Item]
        ) async -> String? {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            let prompt = prompt(title: title, environmentName: environmentName, items: items)
            return await withTaskGroup(of: String?.self) { group in
                group.addTask {
                    let session = LanguageModelSession(
                        instructions: """
                            You write the body of an iOS notification that sums up several alerts \
                            from a Docker management server. Reply with one plain sentence of at \
                            most 140 characters. Name the most important resources exactly as \
                            given. No greeting, emoji, markdown, or quotes, and don't repeat the \
                            summary line or environment name.
                            """
                    )
                    let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 80)
                    guard let response = try? await session.respond(to: prompt, options: options) else {
                        return nil
                    }
                    return clean(response.content)
                }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
        }
    #endif
}
