import SwiftUI
import UIKit
import Arcane

struct LogsView: View {
    let title: String
    let logStream: (Bool) -> LogStream?
    var embedded: Bool = false

    @State private var lines: [IdentifiedLogLine] = []
    /// Incrementally-maintained filter result. Recomputing `lines.filter` in a
    /// computed property was O(n) per access, and body read it three times per
    /// streamed line — the hottest path in the app. New lines are appended here
    /// when they match; only a search-text change triggers a full refilter.
    @State private var filteredLines: [IdentifiedLogLine] = []
    @State private var nextLineID: UInt64 = 0
    @State private var isStreaming = false
    @State private var autoScroll = true
    @State private var newLinesWhilePaused = 0
    @State private var searchText = ""
    @State private var shareFile: LogShareFile?
    @AppStorage("arcane.logs.showTimestamps") private var showTimestamps = false
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var exportLines: [IdentifiedLogLine] {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? lines : filteredLines
    }

    private var exportText: String {
        exportLines.map { $0.line.exportText }.joined(separator: "\n")
    }

    private var hasExportText: Bool {
        !exportLines.isEmpty
    }

    private func matchesFilter(_ entry: IdentifiedLogLine) -> Bool {
        searchText.isEmpty || entry.line.text.localizedCaseInsensitiveContains(searchText)
    }

    private func refilter() {
        filteredLines = searchText.isEmpty ? lines : lines.filter(matchesFilter)
    }

    var body: some View {
        if embedded {
            content
                .task(id: showTimestamps) { await startStreaming() }
                .sheet(item: $shareFile) { file in
                    LogActivityShareSheet(url: file.url)
                }
        } else {
            NavigationStack {
                content
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
                    .searchable(text: $searchText, prompt: "Filter logs")
                    .onChange(of: searchText) { _, _ in refilter() }
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Done") { dismiss() }
                        }
                        // Plain toolbar items — the nav bar supplies its own
                        // glass; a nested GlassContainerCompat here rendered
                        // the spinner and trash button overlapping.
                        if isStreaming {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                            if #available(iOS 26, *) {
                                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                            }
                        }
                        ToolbarItem(placement: .navigationBarTrailing) {
                            optionsMenu
                        }
                    }
                    .task(id: showTimestamps) { await startStreaming() }
                    .sheet(item: $shareFile) { file in
                        LogActivityShareSheet(url: file.url)
                    }
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
                .motionAwareAnimation(isStreaming ? nil : .linear(duration: 0.12), value: filteredLines.count)
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
                if embedded {
                    optionsMenu
                        .frame(width: 42, height: 42)
                        .glassEffectCompat(interactive: true, in: .circle)
                }
                Button {
                    withAnimation {
                        autoScroll.toggle()
                        if autoScroll { newLinesWhilePaused = 0 }
                    }
                } label: {
                    Label(
                        autoScroll ? "Live" : "Paused",
                        systemImage: autoScroll ? "arrow.down.circle.fill" : "pause.circle.fill"
                    )
                        .font(.caption.bold())
                        .contentTransition(.symbolEffect(.replace))
                }
                .glassButtonStyleCompat()
                .padding(16)
            }
        }
        .background(Color(.systemBackground))
    }

    private var optionsMenu: some View {
        Menu {
            Toggle(isOn: $showTimestamps) {
                Label("Timestamps", systemImage: "clock")
            }
            Button {
                copyAllLogs()
            } label: {
                Label("Copy All", systemImage: "doc.on.doc")
            }
            .disabled(!hasExportText)
            Button {
                shareLogs()
            } label: {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            .disabled(!hasExportText)
            Divider()
            Button(role: .destructive) {
                clearLogs()
            } label: {
                Label("Clear", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.primary)
        }
        .accessibilityLabel("Log options")
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

}

private extension LogsView {
    func startStreaming() async {
        guard let stream = logStream(showTimestamps) else { return }
        await MainActor.run {
            clearLogs()
            isStreaming = true
        }
        do {
            let clock = ContinuousClock()
            var lastFlush = clock.now
            var batch: [LogLine] = []

            for try await line in stream {
                guard !Task.isCancelled else { break }
                batch.append(line)
                let now = clock.now
                if lastFlush.duration(to: now) >= .milliseconds(50) || batch.count >= 50 {
                    let linesToAppend = batch
                    batch.removeAll(keepingCapacity: true)
                    lastFlush = now
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        appendStreamedLines(linesToAppend)
                    }
                }
            }
            if !batch.isEmpty && !Task.isCancelled {
                let linesToAppend = batch
                await MainActor.run {
                    appendStreamedLines(linesToAppend)
                }
            }
        } catch {
            // Stream ended or error
        }
        await MainActor.run {
            if !Task.isCancelled {
                isStreaming = false
            }
        }
    }

    func appendStreamedLines(_ newLines: [LogLine]) {
        guard !newLines.isEmpty else { return }
        var newEntries: [IdentifiedLogLine] = []
        newEntries.reserveCapacity(newLines.count)
        var newFiltered: [IdentifiedLogLine] = []

        for line in newLines {
            let entry = IdentifiedLogLine(id: nextLineID, line: line)
            nextLineID &+= 1
            newEntries.append(entry)
            if matchesFilter(entry) {
                newFiltered.append(entry)
            }
        }

        lines.append(contentsOf: newEntries)
        if !newFiltered.isEmpty {
            filteredLines.append(contentsOf: newFiltered)
        }

        trimRetainedWindowIfNeeded()
        if !autoScroll {
            newLinesWhilePaused += newLines.count
        }
    }

    func trimRetainedWindowIfNeeded() {
        guard lines.count > 5000 else { return }
        let overflow = lines.count - 5000
        lines.removeSubrange(0..<overflow)
        if let minID = lines.first?.id {
            let dropCount = filteredLines.prefix(while: { $0.id < minID }).count
            if dropCount > 0 {
                filteredLines.removeSubrange(0..<dropCount)
            }
        }
    }

    func clearLogs() {
        lines.removeAll()
        filteredLines.removeAll()
        nextLineID = 0
        newLinesWhilePaused = 0
    }

    func copyAllLogs() {
        let text = exportText
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        showToast(.copied())
    }

    func shareLogs() {
        let text = exportText
        guard !text.isEmpty else { return }
        do {
            let url = try writeExportFile(text: text)
            shareFile = LogShareFile(url: url)
        } catch {
            showToast(.error("Couldn't export logs"))
        }
    }

    func writeExportFile(text: String) throws -> URL {
        let filename = "\(sanitizedFilename(title))-\(Self.exportDateFormatter.string(from: Date())).log"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func sanitizedFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "logs" : collapsed
    }

    static let exportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

private struct LogShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct LogActivityShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private extension LogLine {
    var exportText: String {
        if let timestamp, !timestamp.isEmpty {
            return "[\(timestamp)] \(text)"
        }
        return text
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
            if let timestamp = line.timestamp {
                Text(timestamp.logTimestamp)
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
        if let formatted = ArcaneDateFormatting.formattedClockTime(fromISO8601: self) {
            return formatted
        }
        // Fallback: just show last 8 chars
        return count > 8 ? String(suffix(8)) : self
    }
}
