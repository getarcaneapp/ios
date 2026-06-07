import SwiftUI
import Arcane

struct LogsView: View {
    let title: String
    let logStream: LogStream?
    var embedded: Bool = false

    @State private var lines: [IdentifiedLogLine] = []
    @State private var nextLineID: UInt64 = 0
    @State private var isStreaming = false
    @State private var autoScroll = true
    @State private var newLinesWhilePaused = 0
    @State private var searchText = ""
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var filteredLines: [IdentifiedLogLine] {
        guard !searchText.isEmpty else { return lines }
        return lines.filter { $0.line.text.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        if embedded {
            content
                .task { await startStreaming() }
        } else {
            NavigationStack {
                content
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
                    .searchable(text: $searchText, prompt: "Filter logs")
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Done") { dismiss() }
                        }
                        ToolbarItem(placement: .navigationBarTrailing) {
                            GlassContainerCompat(spacing: 8) {
                                HStack(spacing: 8) {
                                    if isStreaming {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                            .glassEffectCompat()
                                    }
                                    Button {
                                        lines.removeAll()
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .glassEffectCompat()
                                }
                            }
                        }
                    }
                    .task { await startStreaming() }
            }
        }
    }

    private var content: some View {
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                List {
                    ForEach(filteredLines) { entry in
                        LogLineView(line: entry.line)
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init(top: 1, leading: 12, bottom: 1, trailing: 12))
                            .transition(.opacity)
                    }
                }
                .listStyle(.plain)
                .motionAwareAnimation(.linear(duration: 0.12), value: filteredLines.count)
                .onChange(of: filteredLines.last?.id) { _, lastID in
                    if autoScroll, let lastID {
                        withAnimation(.none) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    if !autoScroll && newLinesWhilePaused > 0 {
                        newLinesPill {
                            resumeAndJumpToBottom(proxy: proxy)
                        }
                        .padding(.bottom, 64)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .motionAwareAnimation(Motion.state, value: newLinesWhilePaused > 0)
            }

            HStack {
                Spacer()
                Button {
                    withAnimation {
                        autoScroll.toggle()
                        if autoScroll { newLinesWhilePaused = 0 }
                    }
                } label: {
                    Label(autoScroll ? "Live" : "Paused", systemImage: autoScroll ? "arrow.down.circle.fill" : "pause.circle.fill")
                        .font(.caption.bold())
                        .contentTransition(.symbolEffect(.replace))
                }
                .glassButtonStyleCompat()
                .padding(16)
            }
        }
        .background(Color(.systemBackground))
    }

    private func newLinesPill(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                    .font(.caption.bold())
                Text("\(newLinesWhilePaused) new")
                    .font(.caption.bold())
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(Color.accentColor, in: .capsule)
        .glassEffectOverlayCompat(interactive: true, in: .capsule)
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        .accessibilityLabel("\(newLinesWhilePaused) new log lines. Tap to jump to latest.")
    }

    private func resumeAndJumpToBottom(proxy: ScrollViewProxy) {
        withAnimation {
            autoScroll = true
            newLinesWhilePaused = 0
        }
        if let lastID = filteredLines.last?.id {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }

    private func startStreaming() async {
        guard let stream = logStream else { return }
        isStreaming = true
        do {
            for try await line in stream {
                await MainActor.run {
                    lines.append(IdentifiedLogLine(id: nextLineID, line: line))
                    nextLineID &+= 1
                    if lines.count > 5000 {
                        lines.removeFirst(100)
                    }
                    if !autoScroll {
                        newLinesWhilePaused += 1
                    }
                }
            }
        } catch {
            // Stream ended or error
        }
        isStreaming = false
    }
}

struct LogLineView: View {
    let line: LogLine

    private var color: Color {
        switch line.level?.lowercased() {
        case "error", "err": return .red
        case "warn", "warning": return .orange
        case "debug": return .secondary
        default: return .primary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let ts = line.timestamp {
                Text(ts.logTimestamp)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
            }
            Text(line.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension String {
    var logTimestamp: String {
        // Try to parse ISO timestamp and show just time
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: self) {
            return date.formatted(.dateTime.hour().minute().second())
        }
        // Fallback: just show last 8 chars
        return count > 8 ? String(suffix(8)) : self
    }
}
