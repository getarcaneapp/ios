import SwiftUI
import Arcane

struct ContainerTerminalView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let container: ContainerInfo
    let environmentID: EnvironmentID

    @State private var output: String = ""
    @State private var input: String = ""
    @State private var session: TerminalSession?
    @State private var connectError: String?
    @State private var isConnecting = false
    @State private var isConnected = false
    @State private var shell: String = "/bin/sh"
    @State private var outputTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool

    private let charBudget = 200_000

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let connectError {
                    errorBanner(connectError)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        Text(output.isEmpty ? "Connecting to \(shell)…" : output)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .id("bottom")
                    }
                    .background(Color(.systemBackground))
                    .onChange(of: output) { _, _ in
                        withAnimation(.linear(duration: 0.1)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }

                Divider()

                inputBar
            }
            .navigationTitle(container.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        Task {
                            await teardown()
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Shell", selection: $shell) {
                            Text("/bin/sh").tag("/bin/sh")
                            Text("/bin/bash").tag("/bin/bash")
                            Text("/bin/zsh").tag("/bin/zsh")
                            Text("/bin/ash").tag("/bin/ash")
                        }
                        .disabled(isConnected || isConnecting)

                        Button(role: .destructive) {
                            output = ""
                        } label: {
                            Label("Clear Output", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "terminal")
                    }
                }
            }
            .task { await connect() }
            .onDisappear {
                Task { await teardown() }
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    shortcutButton("Tab") { Task { try? await session?.send("\t") } }
                    shortcutButton("Esc") { Task { try? await session?.send("\u{001b}") } }
                    shortcutButton("Ctrl+C") { Task { try? await session?.send("\u{0003}") } }
                    shortcutButton("Ctrl+D") { Task { try? await session?.send("\u{0004}") } }
                    shortcutButton("↑") { Task { try? await session?.send("\u{001b}[A") } }
                    shortcutButton("↓") { Task { try? await session?.send("\u{001b}[B") } }
                }
                .padding(.horizontal, 4)
            }

            HStack(spacing: 10) {
                Text("$")
                    .font(.system(.body, design: .monospaced).bold())
                    .foregroundStyle(.secondary)
                TextField("command", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .submitLabel(.send)
                    .focused($inputFocused)
                    .onSubmit { sendInput() }
                Button {
                    sendInput()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(input.isEmpty || !isConnected ? Color.secondary : Color.accentColor)
                }
                .disabled(!isConnected || input.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.tertiarySystemBackground), in: .rect(cornerRadius: 12))
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.regularMaterial)
    }

    private func shortcutButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.monospaced())
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(Color(.tertiarySystemBackground), in: .capsule)
                .foregroundStyle(.primary)
        }
        .disabled(!isConnected)
        .buttonStyle(.plain)
        .opacity(isConnected ? 1.0 : 0.5)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
            Spacer()
            Button("Retry") {
                Task { await connect() }
            }
            .font(.caption)
        }
        .padding(10)
        .background(.regularMaterial)
    }

    private func sendInput() {
        guard isConnected, let session else { return }
        let payload = input + "\n"
        // Don't local-echo: the PTY shell echoes what we send.
        Task {
            try? await session.send(payload)
        }
        input = ""
    }

    private func connect() async {
        guard let client = manager.client else {
            connectError = "Not connected to a server."
            return
        }
        guard !isConnected, !isConnecting else { return }
        isConnecting = true
        connectError = nil
        do {
            let s = try await client.containers.terminal(envID: environmentID, id: container.id, shell: shell)
            session = s
            isConnected = true
            isConnecting = false
            inputFocused = true
            outputTask = Task { @concurrent in
                do {
                    for try await chunk in s.output {
                        if Task.isCancelled { break }
                        let raw = String(decoding: chunk, as: UTF8.self)
                        // Auto-reply to cursor-position requests (DSR [6n) so the
                        // shell prompt finishes drawing instead of waiting forever.
                        if raw.contains("\u{001b}[6n") {
                            try? await s.send("\u{001b}[1;1R")
                        }
                        let stripped = AnsiSanitizer.strip(raw)
                        await MainActor.run {
                            appendOutput(stripped)
                        }
                    }
                } catch is CancellationError {
                    // expected
                } catch {
                    await MainActor.run {
                        connectError = "Disconnected: \(friendlyErrorMessage(error))"
                    }
                }
                await MainActor.run {
                    isConnected = false
                }
            }
        } catch {
            connectError = friendlyErrorMessage(error)
            isConnecting = false
        }
    }

    @MainActor
    private func appendOutput(_ text: String) {
        output.append(text)
        if output.count > charBudget {
            let drop = output.count - charBudget + (charBudget / 10)
            output.removeFirst(drop)
        }
    }

    private func teardown() async {
        outputTask?.cancel()
        outputTask = nil
        await session?.close()
        session = nil
        isConnected = false
        isConnecting = false
    }
}

/// Best-effort stripper for ANSI escape sequences emitted by interactive
/// shells. v1 does not interpret them, so we drop the noisy ones rather than
/// printing literal `[6n`, `[?2004h`, etc. Bell (\a) is also discarded.
nonisolated enum AnsiSanitizer {
    static func strip(_ input: String) -> String {
        guard input.contains("\u{001b}") || input.contains("\u{0007}") else { return input }
        var output = String()
        output.reserveCapacity(input.count)

        var iterator = input.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            switch scalar {
            case "\u{0007}":
                continue // bell
            case "\u{001b}":
                consumeEscape(after: &iterator)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }

    /// Consume an ANSI escape sequence starting just after the ESC byte.
    /// Handles CSI (`ESC [ ... <final-byte>`), OSC (`ESC ] ... BEL or ST`),
    /// and short two-byte forms (`ESC ( B`, `ESC =`, etc.).
    private static func consumeEscape(after iterator: inout String.UnicodeScalarView.Iterator) {
        guard let next = iterator.next() else { return }
        switch next {
        case "[":
            // CSI: parameter bytes 0x30–0x3F, intermediate 0x20–0x2F,
            // final 0x40–0x7E (terminates the sequence).
            while let s = iterator.next() {
                let v = s.value
                if v >= 0x40 && v <= 0x7E { return }
            }
        case "]":
            // OSC: terminated by BEL (0x07) or ST (ESC \).
            while let s = iterator.next() {
                if s == "\u{0007}" { return }
                if s == "\u{001b}" {
                    _ = iterator.next() // consume the trailing `\`
                    return
                }
            }
        case "(", ")", "*", "+", "%", "#":
            _ = iterator.next() // designator byte
        default:
            return // single-character escape
        }
    }
}
