import SwiftUI

struct InstallStreamLine: Identifiable, Equatable {
    let id: UUID
    let text: String
    let isError: Bool

    init(id: UUID = UUID(), text: String, isError: Bool = false) {
        self.id = id
        self.text = text
        self.isError = isError
    }
}

enum InstallStreamStatus: Equatable {
    case running
    case success
    case failure(String)

    var isTerminal: Bool {
        if case .running = self { return false }
        return true
    }
}

/// Full-log detail sheet for the active deployment operation, styled as an
/// install console: one dark monospaced surface, a hairline of state up top,
/// flat actions below — no cards, no chrome. The operation lives in
/// `DeploymentActivityStore`, so the sheet is just a window onto it: it can
/// be hidden (swipe or Hide) at any time and the stream keeps running behind
/// the floating pill and the Live Activity.
///
/// Deliberately dark in both appearances — a terminal is a terminal.
struct InstallStreamSheet: View {
    let operation: DeploymentOperation
    let onCancel: () -> Void
    let onDone: () -> Void

    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var cursorOn = false

    private var status: InstallStreamStatus { operation.status }

    // Committed console palette (same in light and dark mode).
    private static let consoleBackground = Color(red: 0.05, green: 0.05, blue: 0.065)
    private static let consoleText = Color.white.opacity(0.87)
    private static let consoleDim = Color.white.opacity(0.42)
    private static let consoleRule = Color.white.opacity(0.10)
    private static let buttonFill = Color.white.opacity(0.08)

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 14)

            progressRule

            console

            actionBar
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
        }
        .background(Self.consoleBackground.ignoresSafeArea())
        .presentationBackground(Self.consoleBackground)
        .presentationDragIndicator(.visible)
        // System bits (drag indicator, ProgressView, selection UI) should
        // match the always-dark surface.
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            statusDot

            Text(operation.title)
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .foregroundStyle(Self.consoleText)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 12)

            if operation.isServerSynced, !status.isTerminal {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.caption2)
                    .foregroundStyle(Self.consoleDim)
                    .accessibilityLabel("Following the server activity")
            }

            Text(phaseLabel)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(phaseTint)
                .lineLimit(1)
                .contentTransition(.opacity)
                .motionAwareAnimation(Motion.state, value: phaseLabel)
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(phaseTint)
            .frame(width: 9, height: 9)
            .opacity(dotDimmed ? 0.35 : 1)
            .animation(
                status.isTerminal || reduceMotion
                    ? .default
                    : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                value: dotDimmed
            )
            .onAppear { if !status.isTerminal && !reduceMotion { cursorOn = true } }
            .onChange(of: status.isTerminal) { _, terminal in
                if terminal { cursorOn = false }
            }
    }

    /// Drives both the status dot pulse and the log cursor blink from one
    /// repeating animation value.
    private var dotDimmed: Bool { cursorOn && !status.isTerminal }

    private var phaseLabel: String {
        switch status {
        case .running: return operation.currentPhase ?? "running"
        case .success: return "complete"
        case .failure: return "failed"
        }
    }

    private var phaseTint: Color {
        switch status {
        case .running: return .accentColor
        case .success: return .green
        case .failure: return .red
        }
    }

    /// A 2pt state line under the header: determinate fill for pulls, a
    /// quiet hairline otherwise. Never a glass element — plain bars resize
    /// fine.
    private var progressRule: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Self.consoleRule)
                if let fraction = operation.progressFraction, !status.isTerminal {
                    Rectangle()
                        .fill(phaseTint)
                        .frame(width: geo.size.width * fraction)
                        .animation(Motion.gauge, value: fraction)
                } else if status.isTerminal {
                    Rectangle().fill(phaseTint)
                }
            }
        }
        .frame(height: 2)
    }

    // MARK: - Console

    private var console: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(operation.lines) { line in
                        lineRow(line)
                            .id(line.id)
                    }
                    if !status.isTerminal {
                        cursorLine
                            .id("cursor")
                    } else if operation.lines.isEmpty {
                        Text("no output")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Self.consoleDim)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .onChange(of: operation.lines.count) { _, _ in
                withAnimation(.none) {
                    if status.isTerminal, let last = operation.lines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    } else {
                        proxy.scrollTo("cursor", anchor: .bottom)
                    }
                }
            }
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [.black.opacity(0), .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 16)
                    Rectangle().fill(.black)
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Blinking block cursor on its own prompt line while the operation runs
    /// — shares the status dot's repeating animation value.
    private var cursorLine: some View {
        Text(operation.lines.isEmpty ? "starting ▊" : "▊")
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(operation.lines.isEmpty ? Self.consoleDim : Self.consoleText)
            .opacity(dotDimmed ? 0.25 : 1)
            .animation(
                reduceMotion
                    ? .default
                    : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                value: dotDimmed
            )
    }

    private func lineRow(_ line: InstallStreamLine) -> some View {
        Text(attributedLine(line))
            .font(.system(.caption, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private func attributedLine(_ line: InstallStreamLine) -> AttributedString {
        if line.isError {
            var attr = AttributedString(line.text)
            attr.foregroundColor = .red
            return attr
        }
        var attr = AttributedString(line.text)
        attr.foregroundColor = Self.consoleText
        if let prefixEnd = servicePrefixEnd(line.text) {
            let endIndex = attr.characters.index(attr.startIndex, offsetBy: prefixEnd)
            attr[attr.startIndex..<endIndex].foregroundColor = .accentColor
        }
        return attr
    }

    private func servicePrefixEnd(_ text: String) -> Int? {
        guard text.first == "[" else { return nil }
        guard let close = text.firstIndex(of: "]"), close > text.startIndex else { return nil }
        let distance = text.distance(from: text.startIndex, to: close) + 1
        guard distance <= 64 else { return nil }
        return distance
    }

    // MARK: - Actions

    private var actionBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    copyTranscript()
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Self.consoleText)
                        .frame(width: 46, height: 46)
                        .background(Self.buttonFill, in: .circle)
                }
                .buttonStyle(.pressable)
                .disabled(operation.lines.isEmpty)
                .opacity(operation.lines.isEmpty ? 0.4 : 1)
                .accessibilityLabel("Copy log to clipboard")

                if !status.isTerminal {
                    flatButton("Cancel", textColor: .red, fill: Self.buttonFill) {
                        onCancel()
                    }
                    flatButton("Hide", textColor: .white, fill: Color.accentColor) {
                        dismiss()
                    }
                } else {
                    flatButton(
                        doneLabel,
                        textColor: .white,
                        fill: phaseTint
                    ) {
                        onDone()
                        dismiss()
                    }
                }
            }

            if !status.isTerminal {
                Text("Hiding keeps the operation running.")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Self.consoleDim)
            }
        }
    }

    private func flatButton(
        _ title: String, textColor: Color, fill: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(fill, in: .capsule)
        }
        .buttonStyle(.pressable)
    }

    private var doneLabel: String {
        switch status {
        case .running: return "Running…"
        case .success: return "Done"
        case .failure: return "Close"
        }
    }

    private func copyTranscript() {
        let joined = operation.lines.map(\.text).joined(separator: "\n")
        UIPasteboard.general.string = joined
        showToast(.copied("Logs copied"))
    }
}
