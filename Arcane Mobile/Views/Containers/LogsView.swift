import Arcane
import SwiftUI
import UIKit

private enum LogViewerLayout {
    static let wideMinimumWidth: CGFloat = 640
}

enum LogMetadataLayout: Equatable {
    case compact
    case wide
}

struct LogsView: View {
    let title: String
    let embedded: Bool

    @State private var store: LogViewerStore
    @State private var isExpanded = false
    @AppStorage(LogViewerPreferences.showTimestampsKey)
    private var showTimestamps = LogViewerPreferences.showsTimestampsByDefault
    @AppStorage(LogViewerPreferences.wrapLinesKey)
    private var wrapLines = LogViewerPreferences.wrapsLinesByDefault

    init(
        title: String,
        logStream: @escaping () -> BoundedLogStream?,
        embedded: Bool = false
    ) {
        self.title = title
        self.embedded = embedded
        _store = State(initialValue: LogViewerStore(logStream: logStream))
    }

    var body: some View {
        Group {
            if embedded {
                LogViewerSurface(
                    title: title,
                    store: store,
                    embedded: true,
                    showTimestamps: $showTimestamps,
                    wrapLines: $wrapLines,
                    isExpanded: $isExpanded
                )
                .fullScreenCover(isPresented: $isExpanded) {
                    LogViewerDedicatedView(
                        title: title,
                        store: store,
                        showTimestamps: $showTimestamps,
                        wrapLines: $wrapLines
                    )
                    .onAppear { store.start() }
                }
                .onAppear { store.start() }
                .onDisappear {
                    if !isExpanded {
                        store.stop()
                    }
                }
            } else {
                LogViewerDedicatedView(
                    title: title,
                    store: store,
                    showTimestamps: $showTimestamps,
                    wrapLines: $wrapLines
                )
                .onAppear { store.start() }
                .onDisappear { store.stop() }
            }
        }
        .onChange(of: showTimestamps, initial: true) { _, isVisible in
            store.setTimestampVisibility(isVisible)
        }
    }
}

private struct LogViewerDedicatedView: View {
    let title: String
    let store: LogViewerStore
    @Binding var showTimestamps: Bool
    @Binding var wrapLines: Bool

    @SwiftUI.Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LogViewerSurface(
                title: title,
                store: store,
                embedded: false,
                showTimestamps: $showTimestamps,
                wrapLines: $wrapLines,
                isExpanded: .constant(false)
            )
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct LogViewerSurface: View {
    let title: String
    @Bindable var store: LogViewerStore
    let embedded: Bool
    @Binding var showTimestamps: Bool
    @Binding var wrapLines: Bool
    @Binding var isExpanded: Bool

    @State private var isWide = false
    @State private var shareFile: LogShareFile?
    @SwiftUI.Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var metadataLayout: LogMetadataLayout {
        isWide && !dynamicTypeSize.isAccessibilitySize ? .wide : .compact
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            LogConsole(
                store: store,
                showTimestamps: showTimestamps,
                wrapLines: wrapLines,
                metadataLayout: metadataLayout
            )
        }
        .background(Color(.systemBackground))
        .searchable(text: $store.searchText, prompt: "Filter logs")
        .onGeometryChange(for: Bool.self) { [wideMinimumWidth = LogViewerLayout.wideMinimumWidth] proxy in
            proxy.size.width >= wideMinimumWidth
        } action: { newValue in
            if isWide != newValue {
                isWide = newValue
            }
        }
        .toolbar {
            if !embedded {
                ToolbarItem(placement: .topBarTrailing) {
                    optionsMenu
                }
            }
        }
        .sheet(item: $shareFile) { file in
            LogActivityShareSheet(url: file.url)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            LogConnectionIndicator(state: store.connectionState)

            Text(statusLabel)
                .font(.caption.weight(.semibold))
                .lineLimit(1)

            Text(countLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            if case .failed = store.connectionState {
                Button("Retry", systemImage: "arrow.clockwise") {
                    store.retry()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .accessibilityHint("Reconnects without clearing received logs")
            }

            if embedded {
                Button("Expand logs", systemImage: "arrow.up.left.and.arrow.down.right") {
                    isExpanded = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .controlSize(.small)

                optionsMenu
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Log stream controls")
    }

    private var optionsMenu: some View {
        Menu {
            Toggle(isOn: $showTimestamps) {
                Label("Timestamps", systemImage: "clock")
            }
            Toggle(isOn: $wrapLines) {
                Label("Wrap Lines", systemImage: "text.justify.left")
            }

            Divider()

            Button {
                copyLogs()
            } label: {
                Label(copyLabel, systemImage: "doc.on.doc")
            }
            .disabled(store.exportLines.isEmpty)

            Button {
                shareLogs()
            } label: {
                Label(shareLabel, systemImage: "square.and.arrow.up")
            }
            .disabled(store.exportLines.isEmpty)

            Divider()

            Button(role: .destructive) {
                store.clear()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(store.lines.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.primary)
        }
        .accessibilityLabel("Log options")
    }

    private var statusLabel: String {
        switch store.connectionState {
        case .idle: "Disconnected"
        case .connecting: "Connecting"
        case .live: store.lines.isEmpty ? "Waiting for output" : "Live"
        case .ended: "Stream ended"
        case .failed: "Connection failed"
        }
    }

    private var countLabel: String {
        if store.hasActiveSearch {
            return "\(store.filteredLines.count) of \(store.lines.count) lines"
        }
        return "\(store.lines.count) lines"
    }

    private var copyLabel: String {
        store.hasActiveSearch ? "Copy Results" : "Copy All"
    }

    private var shareLabel: String {
        store.hasActiveSearch ? "Share Results…" : "Share All…"
    }

    private func copyLogs() {
        let text = store.exportText(showTimestamps: showTimestamps)
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        showToast(.copied())
    }

    private func shareLogs() {
        let text = store.exportText(showTimestamps: showTimestamps)
        guard !text.isEmpty else { return }

        do {
            let filename = "\(LogViewerFormatting.sanitizedFilename(title))-\(Self.exportDateFormatter.string(from: Date())).log"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try text.write(to: url, atomically: true, encoding: .utf8)
            shareFile = LogShareFile(url: url)
        } catch {
            showToast(.error("Couldn't export logs"))
        }
    }

    private static let exportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

private struct LogConnectionIndicator: View {
    let state: LogViewerConnectionState

    var body: some View {
        switch state {
        case .connecting:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Connecting")
        case .live:
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
                .accessibilityLabel("Live")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityLabel("Connection failed")
        case .ended:
            Image(systemName: "stop.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Stream ended")
        case .idle:
            Circle()
                .fill(.secondary)
                .frame(width: 8, height: 8)
                .accessibilityLabel("Disconnected")
        }
    }
}

private struct LogConsole: View {
    let store: LogViewerStore
    let showTimestamps: Bool
    let wrapLines: Bool
    let metadataLayout: LogMetadataLayout

    @State private var anchoredLineID: UInt64?
    @State private var userIsScrolling = false
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var scrollAxes: Axis.Set {
        wrapLines ? .vertical : [.horizontal, .vertical]
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(scrollAxes) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.filteredLines.isEmpty {
                        LogViewerEmptyState(
                            connectionState: store.connectionState,
                            hasActiveSearch: store.hasActiveSearch,
                            searchText: store.searchText,
                            retry: store.retry
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 72)
                    } else {
                        ForEach(store.filteredLines) { entry in
                            LogLineView(
                                line: entry.line,
                                showTimestamps: showTimestamps,
                                wrapLines: wrapLines,
                                metadataLayout: metadataLayout
                            )
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .frame(maxWidth: wrapLines ? .infinity : nil, alignment: .leading)
                            .background(
                                entry.id.isMultiple(of: 2)
                                    ? Color(.secondarySystemBackground).opacity(0.45)
                                    : Color.clear
                            )
                            .overlay(alignment: .bottom) {
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxWidth: wrapLines ? .infinity : nil, alignment: .leading)
                .scrollTargetLayout()
            }
            .scrollPosition(id: $anchoredLineID, anchor: .top)
            .onScrollPhaseChange { _, newPhase in
                switch newPhase {
                case .tracking, .interacting, .decelerating:
                    userIsScrolling = true
                case .idle, .animating:
                    userIsScrolling = false
                @unknown default:
                    userIsScrolling = false
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 28
            } action: { _, newValue in
                if newValue {
                    store.resumeFollowing()
                } else if userIsScrolling {
                    store.pauseFollowing()
                }
            }
            .onChange(of: store.filteredLines.last?.id) { _, lastID in
                guard store.isFollowing, let lastID else { return }
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
            .onAppear {
                guard store.isFollowing, let lastID = store.filteredLines.last?.id else { return }
                proxy.scrollTo(lastID, anchor: .bottom)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                followControls(proxy: proxy)
            }
        }
        .background(Color(.systemBackground))
    }

    private func followControls(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 10) {
            if !store.isFollowing, store.newLinesWhilePaused > 0 {
                Button {
                    resumeAndJumpToBottom(proxy: proxy)
                } label: {
                    Label {
                        Text(verbatim: "\(store.newLinesWhilePaused) new")
                    } icon: {
                        Image(systemName: "arrow.down")
                    }
                    .font(.caption.bold())
                    .monospacedDigit()
                    .contentTransition(.numericText())
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .accessibilityLabel(
                    Text(verbatim: "\(store.newLinesWhilePaused) new matching log lines")
                )
                .accessibilityHint("Jumps to the latest result")
            }

            Spacer(minLength: 0)

            Button {
                resumeAndJumpToBottom(proxy: proxy)
            } label: {
                Label(
                    store.isFollowing ? "Live" : "Paused",
                    systemImage: store.isFollowing
                        ? "arrow.down.circle.fill"
                        : "pause.circle.fill"
                )
                .font(.caption.bold())
                .contentTransition(.symbolEffect(.replace))
            }
            .glassButtonStyleCompat()
            .controlSize(.small)
            .accessibilityHint(
                store.isFollowing
                    ? "Jumps to the latest log line"
                    : "Resumes following new log lines"
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
        .motionAwareAnimation(Motion.state, value: store.isFollowing)
        .motionAwareAnimation(Motion.state, value: store.newLinesWhilePaused > 0)
    }

    private func resumeAndJumpToBottom(proxy: ScrollViewProxy) {
        store.resumeFollowing()
        guard let lastID = store.filteredLines.last?.id else { return }
        withAnimation(Motion.reduced(Motion.state, reduceMotion: reduceMotion)) {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }
}

private struct LogViewerEmptyState: View {
    let connectionState: LogViewerConnectionState
    let hasActiveSearch: Bool
    let searchText: String
    let retry: () -> Void

    var body: some View {
        if hasActiveSearch {
            ContentUnavailableView {
                Label("No Matches", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("No log lines match “\(searchText)”.")
            }
        } else {
            switch connectionState {
            case .connecting:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Connecting to log stream…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .live:
                ContentUnavailableView(
                    "Waiting for Output",
                    systemImage: "text.alignleft",
                    description: Text("The stream is connected and waiting for new log lines.")
                )
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load Logs", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry", systemImage: "arrow.clockwise", action: retry)
                        .buttonStyle(.borderedProminent)
                }
            case .ended:
                ContentUnavailableView(
                    "No Log Output",
                    systemImage: "text.alignleft",
                    description: Text("The stream ended without returning any log lines.")
                )
            case .idle:
                ContentUnavailableView(
                    "Logs Disconnected",
                    systemImage: "wifi.slash",
                    description: Text("Reopen the viewer or retry the connection.")
                )
            }
        }
    }
}

struct LogLineView: View {
    let line: LogLine
    let showTimestamps: Bool
    let wrapLines: Bool
    let metadataLayout: LogMetadataLayout

    @SwiftUI.Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var severity: LogViewerSeverity {
        LogViewerFormatting.severity(for: line.level)
    }

    private var messageColor: Color {
        switch severity {
        case .error: .red
        case .warning: .orange
        case .debug: .secondary
        case .standard: .primary
        }
    }

    private var hasVisibleMetadata: Bool {
        (showTimestamps && line.timestamp?.isEmpty == false)
            || line.service?.isEmpty == false
            || LogViewerFormatting.levelLabel(line.level) != nil
    }

    var body: some View {
        Group {
            switch metadataLayout {
            case .compact:
                compactLayout
            case .wide:
                wideLayout
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            LogViewerFormatting.accessibilityText(
                for: line,
                showTimestamps: showTimestamps
            )
        )
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            if hasVisibleMetadata {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 3) {
                        metadataViews
                    }
                } else {
                    HStack(spacing: 8) {
                        metadataViews
                    }
                }
            }
            messageView
        }
        .frame(maxWidth: wrapLines ? .infinity : nil, alignment: .leading)
    }

    private var wideLayout: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if showTimestamps {
                metadataText(
                    line.timestamp.map(LogViewerFormatting.displayTimestamp) ?? "",
                    color: .secondary
                )
                .frame(width: 82, alignment: .leading)
            }

            metadataText(line.service ?? "", color: .secondary)
                .lineLimit(1)
                .frame(width: 110, alignment: .leading)

            metadataText(
                LogViewerFormatting.levelLabel(line.level) ?? "",
                color: metadataColor
            )
            .frame(width: 58, alignment: .leading)

            messageView
                .frame(maxWidth: wrapLines ? .infinity : nil, alignment: .leading)
        }
    }

    @ViewBuilder
    private var metadataViews: some View {
        if showTimestamps,
           let timestamp = line.timestamp,
           !timestamp.isEmpty {
            metadataText(
                LogViewerFormatting.displayTimestamp(timestamp),
                color: .secondary
            )
        }
        if let service = line.service, !service.isEmpty {
            Label {
                Text(service)
            } icon: {
                Image(systemName: "shippingbox")
            }
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        if let level = LogViewerFormatting.levelLabel(line.level) {
            metadataText(level, color: metadataColor)
                .fontWeight(.semibold)
        }
    }

    @ViewBuilder
    private var messageView: some View {
        if wrapLines {
            Text(line.text)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(messageColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(line.text)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(messageColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
        }
    }

    private var metadataColor: Color {
        switch severity {
        case .error: .red
        case .warning: .orange
        case .debug, .standard: .secondary
        }
    }

    private func metadataText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(color)
    }
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
