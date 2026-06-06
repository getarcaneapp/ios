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

struct InstallStreamSheet: View {
    let title: String
    let status: InstallStreamStatus
    let currentPhase: String?
    let seenPhases: [String]
    let lines: [InstallStreamLine]
    let onDismiss: () -> Void

    @SwiftUI.Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            header
            if seenPhases.count >= 2 {
                phaseStrip
            }
            terminal
            actionRow
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 18)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .presentationDragIndicator(.hidden)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            iconBadge
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                phasePill
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassEffectCompat(in: .rect(cornerRadius: 22))
    }

    private var iconBadge: some View {
        Group {
            switch status {
            case .running:
                Image(systemName: "shippingbox.fill")
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
        case .running: return currentPhase.map { "\($0)…" } ?? "Streaming…"
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
                ForEach(Array(seenPhases.enumerated()), id: \.element) { _, phase in
                    phasePillRow(phase)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
    }

    private func phasePillRow(_ phase: String) -> some View {
        let isCurrent = (phase == currentPhase) && !status.isTerminal
        let isDone = (phase != currentPhase) || status.isTerminal

        return HStack(spacing: 4) {
            if isDone && !isCurrent {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
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
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.clear)
                .glassEffectCompat(in: .rect(cornerRadius: 20))

            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            if lines.isEmpty {
                                emptyState
                            } else {
                                ForEach(lines) { line in
                                    lineRow(line)
                                        .id(line.id)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                    .onChange(of: lines.count) { _, _ in
                        if let last = lines.last {
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
        HStack(spacing: 12) {
            Button {
                copyTranscript()
            } label: {
                Label("Copy", systemImage: "doc.on.clipboard")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
            }
            .glassButtonStyleCompat()
            .disabled(lines.isEmpty)
            .accessibilityLabel("Copy log to clipboard")

            Button {
                onDismiss()
                dismiss()
            } label: {
                Text(doneLabel)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .glassProminentButtonStyleCompat()
            .tint(doneTint)
            .disabled(!status.isTerminal)
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
        let joined = lines.map(\.text).joined(separator: "\n")
        UIPasteboard.general.string = joined
        showToast(.copied("Logs copied"))
    }
}
