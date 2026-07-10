import SwiftUI
import Arcane
import UIKit

struct ContainerTerminalView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let container: ContainerSummary
    let environmentID: EnvironmentID

    @State private var outputLines: [TerminalOutputLine] = []
    @State private var outputText = ""
    @State private var outputRevision: UInt64 = 0
    @State private var input: String = ""
    @State private var session: TerminalSession?
    @State private var connectError: String?
    @State private var isConnecting = false
    @State private var isConnected = false
    @State private var shell: String = "/bin/sh"
    @State private var outputTask: Task<Void, Never>?
    @State private var outputProcessor = TerminalOutputProcessor()
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let connectError {
                    ErrorBanner(message: connectError, severity: .warning) {
                        Task { await connect() }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if outputLines.isEmpty {
                                Text("Connecting to \(shell)…")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(outputLines) { line in
                                    Text(verbatim: line.text.isEmpty ? " " : line.text)
                                        .id(line.id)
                                }
                            }
                            Color.clear
                                .frame(height: 1)
                                .id("bottom")
                        }
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    }
                    .background(Color(.systemBackground))
                    .onChange(of: outputRevision) { _, _ in
                        withAnimation(Motion.follow) {
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

                        Button {
                            UIPasteboard.general.string = outputText
                            showToast(.copied())
                        } label: {
                            Label("Copy All", systemImage: "doc.on.doc")
                        }
                        .disabled(outputText.isEmpty)

                        Button(role: .destructive) {
                            Task { await clearOutput() }
                        } label: {
                            Label("Clear Output", systemImage: "trash")
                        }
                        .tint(.red)
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
            let terminalSession = try await client.containers.exec(
                envID: environmentID,
                id: container.id,
                shell: shell
            )
            await outputProcessor.clear()
            outputLines = []
            outputText = ""
            session = terminalSession
            isConnected = true
            isConnecting = false
            inputFocused = true
            let processor = outputProcessor
            outputTask = Task { @concurrent in
                await consumeOutput(from: terminalSession, processor: processor)
            }
        } catch {
            connectError = friendlyErrorMessage(error)
            isConnecting = false
        }
    }
}

private extension ContainerTerminalView {
    @concurrent
    func consumeOutput(
        from terminalSession: TerminalSession,
        processor: TerminalOutputProcessor
    ) async {
        let clock = ContinuousClock()
        var lastFlush: ContinuousClock.Instant?
        do {
            for try await chunk in terminalSession.output {
                if Task.isCancelled { break }
                let replyCount = await processor.append(chunk)
                for _ in 0..<replyCount {
                    try? await terminalSession.send("\u{001b}[1;1R")
                }

                let now = clock.now
                if lastFlush == nil || lastFlush!.duration(to: now) >= .milliseconds(50) {
                    await publish(await processor.snapshot())
                    lastFlush = now
                }
            }
        } catch is CancellationError {
            return
        } catch {
            await MainActor.run {
                connectError = "Disconnected: \(friendlyErrorMessage(error))"
            }
        }

        guard !Task.isCancelled else { return }
        await processor.finish()
        await waitForFlushInterval(after: lastFlush, clock: clock)
        guard !Task.isCancelled else { return }
        await publish(await processor.snapshot())
        await MainActor.run { isConnected = false }
    }

    nonisolated func waitForFlushInterval(
        after lastFlush: ContinuousClock.Instant?,
        clock: ContinuousClock
    ) async {
        guard let lastFlush else { return }
        let minimumInterval: Duration = .milliseconds(50)
        let elapsed = lastFlush.duration(to: clock.now)
        if elapsed < minimumInterval {
            try? await Task.sleep(for: minimumInterval - elapsed)
        }
    }

    func publish(_ snapshot: TerminalOutputSnapshot) {
        guard snapshot.lines != outputLines || snapshot.fullText != outputText else { return }
        outputLines = snapshot.lines
        outputText = snapshot.fullText
        outputRevision &+= 1
    }

    func clearOutput() async {
        await outputProcessor.clear()
        outputLines = []
        outputText = ""
        outputRevision &+= 1
    }

    func teardown() async {
        outputTask?.cancel()
        outputTask = nil
        await session?.close()
        session = nil
        isConnected = false
        isConnecting = false
    }
}
