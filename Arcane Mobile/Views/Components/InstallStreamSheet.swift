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

/// Full-log detail sheet for the active deployment operation. The operation
/// lives in `DeploymentActivityStore`, so the sheet is just a window onto it:
/// it can be hidden (swipe or Hide button) at any time and the stream keeps
/// running behind the floating pill and the Live Activity.
struct InstallStreamSheet: View {
    let operation: DeploymentOperation
    let onCancel: () -> Void
    let onDone: () -> Void

    @SwiftUI.Environment(\.dismiss) private var dismiss

    private var status: InstallStreamStatus { operation.status }

    var body: some View {
        VStack(spacing: 14) {
            header
            if operation.isServerSynced, !status.isTerminal {
                Label("Reattached — following the server activity", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if operation.seenPhases.count >= 2 {
                phaseStrip
            }
            terminal
            actionRow
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 18)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .presentationDragIndicator(.visible)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                iconBadge
                VStack(alignment: .leading, spacing: 6) {
                    Text(operation.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    phasePill
                }
                Spacer(minLength: 0)
            }
            .padding(14)

            if let fraction = operation.progressFraction, !status.isTerminal {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                    .animation(Motion.gauge, value: fraction)
            }
        }
        .glassEffectCompat(in: .rect(cornerRadius: Radius.card))
    }

    private var iconBadge: some View {
        Group {
            switch status {
            case .running:
                Image(systemName: operation.kind.systemImage)
                    .symbolEffect(.pulse, options: .repeating)
                    .foregroundStyle(.blue)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .symbolEffect(.bounce, value: status)
                    .foregroundStyle(.green)
            case .failure:
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
        }
        .font(.system(size: 24, weight: .semibold))
        .frame(width: 48, height: 48)
        .glassEffectCompat(tint: iconTint.opacity(0.25), in: .circle)
    }

    private var iconTint: Color {
        switch status {
        case .running: return .blue
        case .success: return .green
        case .failure: return .red
        }
    }

    private var phasePill: some View {
        HStack(spacing: 6) {
            if case .running = status {
                ProgressView().controlSize(.mini)
            }
            Text(phaseLabel)
                .font(.caption.weight(.semibold))
                .contentTransition(.opacity)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffectCompat(tint: phaseTint.opacity(0.25), in: .capsule)
    }

    private var phaseLabel: String {
        switch status {
        case .running: return operation.currentPhase.map { "\($0)…" } ?? "Streaming…"
        case .success: return "Complete"
        case .failure: return "Failed"
        }
    }

    private var phaseTint: Color {
        switch status {
        case .running: return .accentColor
        case .success: return .green
        case .failure: return .red
        }
    }

    // MARK: - Phase strip

    private var phaseStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(operation.seenPhases.enumerated()), id: \.element) { _, phase in
                    phasePillRow(phase)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
    }

    private func phasePillRow(_ phase: String) -> some View {
        let isCurrent = (phase == operation.currentPhase) && !status.isTerminal
        let isDone = (phase != operation.currentPhase) || status.isTerminal

        return HStack(spacing: 4) {
            if isDone && !isCurrent {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.green)
            }
            Text(phase)
                .font(.caption2.weight(isCurrent ? .bold : .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .glassEffectCompat(
            tint: (isCurrent ? Color.accentColor : Color.green).opacity(isCurrent ? 0.3 : 0.15),
            in: .capsule
        )
    }

    // MARK: - Terminal

    private var terminal: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(.clear)
                .glassEffectCompat(in: .rect(cornerRadius: Radius.card))

            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            if operation.lines.isEmpty {
                                emptyState
                            } else {
                                ForEach(operation.lines) { line in
                                    lineRow(line)
                                        .id(line.id)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                    .onChange(of: operation.lines.count) { _, _ in
                        if let last = operation.lines.last {
                            withAnimation(.none) { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                .mask(
                    VStack(spacing: 0) {
                        Rectangle().fill(.black)
                        LinearGradient(
                            colors: [.black, .black.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 22)
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.8)
            Text(status.isTerminal ? "No output." : "Starting…")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
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
        attr.foregroundColor = .primary
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

    // MARK: - Action row

    private var actionRow: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    copyTranscript()
                } label: {
                    Label("Copy", systemImage: "doc.on.clipboard")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                }
                .glassButtonStyleCompat()
                .disabled(operation.lines.isEmpty)
                .accessibilityLabel("Copy log to clipboard")

                if !status.isTerminal {
                    Button {
                        onCancel()
                    } label: {
                        Text("Cancel")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .glassButtonStyleCompat()
                    .tint(.red)

                    Button {
                        dismiss()
                    } label: {
                        Text("Hide")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .glassProminentButtonStyleCompat()
                    .tint(.accentColor)
                } else {
                    Button {
                        onDone()
                        dismiss()
                    } label: {
                        Text(doneLabel)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .glassProminentButtonStyleCompat()
                    .tint(doneTint)
                }
            }

            if !status.isTerminal {
                Text("Hiding keeps the operation running.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var doneLabel: String {
        switch status {
        case .running: return "Running…"
        case .success: return "Done"
        case .failure: return "Dismiss"
        }
    }

    private var doneTint: Color {
        switch status {
        case .running: return .accentColor
        case .success: return .green
        case .failure: return .red
        }
    }

    private func copyTranscript() {
        let joined = operation.lines.map(\.text).joined(separator: "\n")
        UIPasteboard.general.string = joined
        showToast(.copied("Logs copied"))
    }
}
