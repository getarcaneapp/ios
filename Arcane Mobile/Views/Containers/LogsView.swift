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
    let store: LogViewerStore
    let embedded: Bool
    @Binding var showTimestamps: Bool
    @Binding var wrapLines: Bool
    @Binding var isExpanded: Bool

    @State private var isWide = false
    @State private var jumpToLatestRequest = 0
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
                metadataLayout: metadataLayout,
                jumpToLatestRequest: jumpToLatestRequest
            )
        }
        .background(Color(.systemBackground))
        .onGeometryChange(for: Bool.self) { [wideMinimumWidth = LogViewerLayout.wideMinimumWidth] proxy in
            proxy.size.width >= wideMinimumWidth
        } action: { newValue in
            if isWide != newValue {
                isWide = newValue
            }
        }
        .toolbar {
            if embedded {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isExpanded = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .appAccentToolbarSymbol()
                    }
                    .accessibilityLabel("Expand logs")
                }

                if #available(iOS 26, *) {
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                optionsMenu
            }
        }
        .sheet(item: $shareFile) { file in
            LogActivityShareSheet(url: file.url)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            LogConnectionIndicator(state: store.connectionState)

            Text(statusLabel)
                .font(.caption.weight(.semibold))
                .lineLimit(1)

            Text(countLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if !store.isFollowing {
                Button {
                    store.resumeFollowing()
                    jumpToLatestRequest &+= 1
                } label: {
                    Label(
                        store.newLinesWhilePaused > 0
                            ? "\(store.newLinesWhilePaused) new"
                            : "Latest",
                        systemImage: "arrow.down"
                    )
                    .font(.caption.bold())
                    .monospacedDigit()
                    .contentTransition(.numericText())
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .accessibilityLabel(
                    store.newLinesWhilePaused > 0
                        ? "\(store.newLinesWhilePaused) new log lines"
                        : "Resume following log lines"
                )
                .accessibilityHint("Jumps to the latest log line")
            }

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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Log stream controls")
        .motionAwareAnimation(Motion.state, value: store.isFollowing)
        .motionAwareAnimation(Motion.state, value: store.newLinesWhilePaused > 0)
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
                Label("Copy All", systemImage: "doc.on.doc")
            }
            .disabled(store.lines.isEmpty)

            Button {
                shareLogs()
            } label: {
                Label("Share All…", systemImage: "square.and.arrow.up")
            }
            .disabled(store.lines.isEmpty)

            Divider()

            Button(role: .destructive) {
                store.clear()
            } label: {
                DestructiveLabel(text: "Clear")
            }
            .tint(.red)
            .disabled(store.lines.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle")
                .appAccentToolbarSymbol()
        }
        .accessibilityLabel("Log options")
    }

    private var statusLabel: String {
        switch store.connectionState {
        case .idle: "Disconnected"
        case .connecting: "Connecting"
        case .live:
            if !store.isFollowing {
                "Paused"
            } else {
                store.lines.isEmpty ? "Waiting for output" : "Live"
            }
        case .ended: "Stream ended"
        case .failed: "Connection failed"
        }
    }

    private var countLabel: String {
        "\(store.lines.count) lines"
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

struct LogConsole: View {
    let store: LogViewerStore
    let showTimestamps: Bool
    let wrapLines: Bool
    let metadataLayout: LogMetadataLayout
    let jumpToLatestRequest: Int

    @State private var position = ScrollPosition(idType: LogScrollTarget.self)
    @State private var userIsScrolling = false
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var scrollAxes: Axis.Set {
        wrapLines ? .vertical : [.horizontal, .vertical]
    }

    var body: some View {
        ScrollView(scrollAxes) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if store.lines.isEmpty {
                    LogViewerEmptyState(
                        connectionState: store.connectionState,
                        retry: store.retry
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 72)
                } else {
                    ForEach(store.lines) { entry in
                        LogLineView(
                            line: entry.line,
                            showTimestamps: showTimestamps,
                            wrapLines: wrapLines,
                            metadataLayout: metadataLayout
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
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

                Color.clear
                    .frame(width: 1, height: 1)
                    .id(LogScrollTarget.bottom)
            }
            .frame(maxWidth: wrapLines ? .infinity : nil, alignment: .leading)
            .scrollTargetLayout()
        }
        .scrollPosition($position)
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
        .onChange(of: store.lines.last?.id) { _, lastID in
            guard store.isFollowing, lastID != nil else { return }
            scrollToBottom(animated: false)
        }
        .onAppear {
            guard store.isFollowing, !store.lines.isEmpty else { return }
            scrollToBottom(animated: false)
        }
        .onChange(of: jumpToLatestRequest) { _, _ in
            scrollToBottom(animated: true)
        }
        .background(Color(.systemBackground))
    }

    private func scrollToBottom(animated: Bool) {
        guard !store.lines.isEmpty else { return }

        if animated {
            withAnimation(Motion.reduced(Motion.state, reduceMotion: reduceMotion)) {
                position.scrollTo(id: LogScrollTarget.bottom, anchor: .bottom)
            }
        } else {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                position.scrollTo(id: LogScrollTarget.bottom, anchor: .bottom)
            }
        }
    }
}

private nonisolated enum LogScrollTarget: Hashable, Sendable {
    case bottom
}

private struct LogViewerEmptyState: View {
    let connectionState: LogViewerConnectionState
    let retry: () -> Void

    var body: some View {
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
        VStack(
            alignment: .leading,
            spacing: dynamicTypeSize.isAccessibilitySize ? 6 : 3
        ) {
            if hasVisibleMetadata {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 3) {
                        metadataViews
                    }
                } else {
                    HStack(spacing: 6) {
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
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(messageColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(line.text)
                .font(.system(.caption, design: .monospaced))
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
