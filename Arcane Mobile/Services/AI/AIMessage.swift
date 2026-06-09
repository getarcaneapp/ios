import Foundation

/// One turn in the assistant transcript. Mirrors `messages` in the service;
/// the model's own `transcript` is the source of truth for generation, this is
/// just what we render.
struct AIMessage: Identifiable, Equatable, Sendable {
    enum Role: Sendable { case user, assistant, system }

    let id: UUID
    let role: Role
    var text: String
    /// True while a streamed assistant response is still arriving (drives the caret).
    var isStreaming: Bool

    init(id: UUID = UUID(), role: Role, text: String, isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
    }

    static func user(_ text: String) -> AIMessage { .init(role: .user, text: text) }
    static func system(_ text: String) -> AIMessage { .init(role: .system, text: text) }
    static func assistantPlaceholder() -> AIMessage {
        .init(role: .assistant, text: "", isStreaming: true)
    }
}
