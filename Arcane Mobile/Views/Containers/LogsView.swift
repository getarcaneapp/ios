import SwiftUI
import Arcane

struct LogsView: View {
    let title: String
    let logStream: LogStream?

    @State private var lines: [LogLine] = []
    @State private var isStreaming = false
    @State private var autoScroll = true
    @State private var searchText = ""
    @SwiftUI.Environment(\.dismiss) private var dismiss

    private var filteredLines: [LogLine] {
        guard !searchText.isEmpty else { return lines }
        return lines.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(filteredLines.enumerated()), id: \.offset) { index, line in
                            LogLineView(line: line)
                                .id(index)
                                .listRowBackground(Color.clear)
                                .listRowInsets(.init(top: 1, leading: 12, bottom: 1, trailing: 12))
                        }
                    }
                    .listStyle(.plain)
                    .onChange(of: filteredLines.count) { _, newCount in
                        if autoScroll && newCount > 0 {
                            withAnimation(.none) {
                                proxy.scrollTo(newCount - 1, anchor: .bottom)
                            }
                        }
                    }
                }

                // Auto-scroll toggle
                HStack {
                    Spacer()
                    Button {
                        withAnimation { autoScroll.toggle() }
                    } label: {
                        Label(autoScroll ? "Live" : "Paused", systemImage: autoScroll ? "arrow.down.circle.fill" : "pause.circle.fill")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.glass)
                    .padding(16)
                }
            }
            .background(Color(.systemBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Filter logs")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            if isStreaming {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .glassEffect()
                            }
                            Button {
                                lines.removeAll()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .glassEffect()
                        }
                    }
                }
            }
            .task { await startStreaming() }
        }
    }

    private func startStreaming() async {
        guard let stream = logStream else { return }
        isStreaming = true
        do {
            for try await line in stream {
                await MainActor.run {
                    lines.append(line)
                    // Cap at 5000 lines to avoid memory issues
                    if lines.count > 5000 {
                        lines.removeFirst(100)
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
