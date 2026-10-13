import Arcane
import Foundation
import Observation

enum LogViewerConnectionState: Equatable {
    case idle
    case connecting
    case live
    case ended
    case failed(String)
}

enum LogViewerSeverity: Equatable {
    case standard
    case debug
    case warning
    case error
}

enum LogViewerPreferences {
    static let showTimestampsKey = "arcane.logs.showTimestamps"
    static let wrapLinesKey = "arcane.logs.wrapLines"
    static let showsTimestampsByDefault = false
    static let wrapsLinesByDefault = true
}

enum LogViewerFormatting {
    static func severity(for level: String?) -> LogViewerSeverity {
        switch level?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "error", "err", "stderr": .error
        case "warn", "warning": .warning
        case "debug": .debug
        default: .standard
        }
    }

    static func levelLabel(_ level: String?) -> String? {
        guard let level = level?.trimmingCharacters(in: .whitespacesAndNewlines),
            !level.isEmpty
        else { return nil }

        switch severity(for: level) {
        case .error: return "ERROR"
        case .warning: return "WARN"
        case .debug: return "DEBUG"
        case .standard: return level.uppercased()
        }
    }

    static func displayTimestamp(_ value: String) -> String {
        if let formatted = ArcaneDateFormatting.formattedClockTime(fromISO8601: value) {
            return formatted
        }
        return value.count > 8 ? String(value.suffix(8)) : value
    }

    static func exportText(for line: LogLine, showTimestamps: Bool) -> String {
        var metadata: [String] = []
        if showTimestamps,
            let timestamp = line.timestamp?.trimmingCharacters(in: .whitespacesAndNewlines),
            !timestamp.isEmpty
        {
            metadata.append("[\(timestamp)]")
        }
        if let service = line.service?.trimmingCharacters(in: .whitespacesAndNewlines),
            !service.isEmpty
        {
            metadata.append("[\(service)]")
        }
        if let level = levelLabel(line.level) {
            metadata.append("[\(level)]")
        }
        metadata.append(line.text)
        return metadata.joined(separator: " ")
    }

    static func accessibilityText(for line: LogLine, showTimestamps: Bool) -> String {
        var components: [String] = []
        if showTimestamps,
            let timestamp = line.timestamp?.trimmingCharacters(in: .whitespacesAndNewlines),
            !timestamp.isEmpty
        {
            components.append(displayTimestamp(timestamp))
        }
        if let service = line.service?.trimmingCharacters(in: .whitespacesAndNewlines),
            !service.isEmpty
        {
            components.append("Service \(service)")
        }
        if let level = levelLabel(line.level) {
            components.append(level)
        }
        components.append(line.text)
        return components.joined(separator: ", ")
    }

    static func sanitizedFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "logs" : collapsed
    }
}

/// Per-line values the console row shows, derived once when the line
/// arrives instead of on every render of every visible row.
struct LogLinePresentation: Equatable {
    let severity: LogViewerSeverity
    let levelLabel: String?
    let displayTimestamp: String?

    init(_ line: LogLine) {
        severity = LogViewerFormatting.severity(for: line.level)
        levelLabel = LogViewerFormatting.levelLabel(line.level)
        displayTimestamp = line.timestamp
            .flatMap { $0.isEmpty ? nil : $0 }
            .map(LogViewerFormatting.displayTimestamp)
    }

    func accessibilityText(for line: LogLine, showTimestamps: Bool) -> String {
        var components: [String] = []
        if showTimestamps, let displayTimestamp, !displayTimestamp.isEmpty {
            components.append(displayTimestamp)
        }
        if let service = line.service?.trimmingCharacters(in: .whitespacesAndNewlines), !service.isEmpty {
            components.append("Service \(service)")
        }
        if let levelLabel { components.append(levelLabel) }
        components.append(line.text)
        return components.joined(separator: ", ")
    }
}

struct LogViewerLine: Identifiable {
    let id: UInt64
    let line: LogLine
    let presentation: LogLinePresentation
}

@MainActor
@Observable
final class LogViewerStore {
    static let maximumRetainedLines = 5_000

    private(set) var lines: [LogViewerLine] = []
    private(set) var connectionState: LogViewerConnectionState = .idle
    private(set) var isFollowing = true
    private(set) var newLinesWhilePaused = 0

    @ObservationIgnored private let makeLogStream: () -> BoundedLogStream?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var streamGeneration = 0
    @ObservationIgnored private var nextLineID: UInt64 = 0
    /// Streamed lines waiting for the next publish.
    @ObservationIgnored private var pendingLines: [LogLine] = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// Lines publish at most this often. A timer, not the next arriving line,
    /// drives it, so the tail of a burst shows even when the stream goes quiet.
    private static let flushInterval: Duration = .milliseconds(100)

    init(logStream: @escaping () -> BoundedLogStream?) {
        self.makeLogStream = logStream
    }

    func start() {
        guard streamTask == nil else { return }

        streamGeneration &+= 1
        let generation = streamGeneration
        connectionState = .connecting
        streamTask = Task { [weak self] in
            await self?.consumeStream(generation: generation)
        }
    }

    func stop() {
        streamGeneration &+= 1
        streamTask?.cancel()
        streamTask = nil
        flushPending()
        if connectionState == .connecting || connectionState == .live {
            connectionState = .idle
        }
    }

    func retry() {
        streamGeneration &+= 1
        streamTask?.cancel()
        streamTask = nil
        start()
    }

    func pauseFollowing() {
        guard isFollowing else { return }
        isFollowing = false
    }

    func resumeFollowing() {
        if !isFollowing {
            isFollowing = true
        }
        if newLinesWhilePaused != 0 {
            newLinesWhilePaused = 0
        }
    }

    func clear() {
        pendingLines.removeAll()
        lines.removeAll(keepingCapacity: true)
        newLinesWhilePaused = 0
    }

    func exportText(showTimestamps: Bool) -> String {
        lines
            .map { LogViewerFormatting.exportText(for: $0.line, showTimestamps: showTimestamps) }
            .joined(separator: "\n")
    }

    func receive(_ newLines: [LogLine]) {
        guard !newLines.isEmpty else { return }

        var newEntries: [LogViewerLine] = []
        newEntries.reserveCapacity(newLines.count)

        for var line in newLines {
            line.text = RemoteDataLimits.boundedText(
                line.text,
                maximumBytes: RemoteDataLimits.maximumStreamLineBytes
            )
            line.timestamp = line.timestamp.map {
                RemoteDataLimits.boundedText($0, maximumBytes: 256)
            }
            line.level = line.level.map {
                RemoteDataLimits.boundedText($0, maximumBytes: 64)
            }
            line.service = line.service.map {
                RemoteDataLimits.boundedText($0, maximumBytes: 256)
            }

            let entry = LogViewerLine(id: nextLineID, line: line, presentation: LogLinePresentation(line))
            nextLineID &+= 1
            newEntries.append(entry)
        }

        lines.append(contentsOf: newEntries)
        trimRetainedWindowIfNeeded()

        if !isFollowing {
            newLinesWhilePaused = RemoteDataLimits.saturatingAdd(
                newLinesWhilePaused,
                newEntries.count,
                maximum: Self.maximumRetainedLines
            )
        }
    }

    private func enqueue(_ line: LogLine) {
        pendingLines.append(line)
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flushInterval)
            guard !Task.isCancelled else { return }
            self?.flushPending()
        }
    }

    private func flushPending() {
        flushTask?.cancel()
        flushTask = nil
        guard !pendingLines.isEmpty else { return }
        let batch = pendingLines
        pendingLines.removeAll(keepingCapacity: true)
        receive(batch)
    }

    private func trimRetainedWindowIfNeeded() {
        guard lines.count > Self.maximumRetainedLines else { return }

        let overflow = lines.count - Self.maximumRetainedLines
        lines.removeSubrange(0..<overflow)
    }

    private func consumeStream(generation: Int) async {
        defer {
            if generation == streamGeneration {
                streamTask = nil
            }
        }

        guard let stream = makeLogStream() else {
            if generation == streamGeneration {
                connectionState = .failed("Log stream is unavailable.")
            }
            return
        }

        await Task.yield()
        guard generation == streamGeneration, !Task.isCancelled else { return }
        connectionState = .live

        do {
            for try await line in stream {
                guard generation == streamGeneration, !Task.isCancelled else { return }
                enqueue(line)
            }

            if generation == streamGeneration, !Task.isCancelled {
                flushPending()
                connectionState = .ended
            }
        } catch {
            guard generation == streamGeneration else { return }
            flushPending()
            if Task.isCancelled {
                connectionState = .idle
            } else {
                connectionState = .failed(error.localizedDescription)
            }
        }
    }
}
