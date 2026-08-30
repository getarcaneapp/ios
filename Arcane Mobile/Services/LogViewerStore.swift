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
              !level.isEmpty else { return nil }

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
           !timestamp.isEmpty {
            metadata.append("[\(timestamp)]")
        }
        if let service = line.service?.trimmingCharacters(in: .whitespacesAndNewlines),
           !service.isEmpty {
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
           !timestamp.isEmpty {
            components.append(displayTimestamp(timestamp))
        }
        if let service = line.service?.trimmingCharacters(in: .whitespacesAndNewlines),
           !service.isEmpty {
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

@MainActor
@Observable
final class LogViewerStore {
    static let maximumRetainedLines = 5_000

    private(set) var lines: [IdentifiedLogLine] = []
    private(set) var filteredLines: [IdentifiedLogLine] = []
    private(set) var connectionState: LogViewerConnectionState = .idle
    private(set) var isFollowing = true
    private(set) var newLinesWhilePaused = 0

    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            newLinesWhilePaused = 0
            refilter()
        }
    }

    @ObservationIgnored private let makeLogStream: () -> BoundedLogStream?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var streamGeneration = 0
    @ObservationIgnored private var nextLineID: UInt64 = 0
    @ObservationIgnored private var searchesTimestamps = false

    init(logStream: @escaping () -> BoundedLogStream?) {
        self.makeLogStream = logStream
    }

    var hasActiveSearch: Bool {
        !normalizedSearchText.isEmpty
    }

    var exportLines: [IdentifiedLogLine] {
        hasActiveSearch ? filteredLines : lines
    }

    func setTimestampVisibility(_ isVisible: Bool) {
        guard searchesTimestamps != isVisible else { return }
        searchesTimestamps = isVisible
        newLinesWhilePaused = 0
        refilter()
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
        lines.removeAll(keepingCapacity: true)
        filteredLines.removeAll(keepingCapacity: true)
        newLinesWhilePaused = 0
    }

    func exportText(showTimestamps: Bool) -> String {
        exportLines
            .map { LogViewerFormatting.exportText(for: $0.line, showTimestamps: showTimestamps) }
            .joined(separator: "\n")
    }

    func receive(_ newLines: [LogLine]) {
        guard !newLines.isEmpty else { return }

        let search = normalizedSearchText
        var newEntries: [IdentifiedLogLine] = []
        newEntries.reserveCapacity(newLines.count)
        var newFilteredEntries: [IdentifiedLogLine] = []
        newFilteredEntries.reserveCapacity(newLines.count)

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

            let entry = IdentifiedLogLine(id: nextLineID, line: line)
            nextLineID &+= 1
            newEntries.append(entry)
            if matchesFilter(line, search: search) {
                newFilteredEntries.append(entry)
            }
        }

        lines.append(contentsOf: newEntries)
        filteredLines.append(contentsOf: newFilteredEntries)
        trimRetainedWindowIfNeeded()

        if !isFollowing, !newFilteredEntries.isEmpty {
            newLinesWhilePaused = RemoteDataLimits.saturatingAdd(
                newLinesWhilePaused,
                newFilteredEntries.count,
                maximum: Self.maximumRetainedLines
            )
        }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refilter() {
        let search = normalizedSearchText
        filteredLines = search.isEmpty
            ? lines
            : lines.filter { matchesFilter($0.line, search: search) }
    }

    private func matchesFilter(_ line: LogLine, search: String) -> Bool {
        guard !search.isEmpty else { return true }
        if line.text.localizedCaseInsensitiveContains(search) { return true }
        if line.service?.localizedCaseInsensitiveContains(search) == true { return true }
        if line.level?.localizedCaseInsensitiveContains(search) == true { return true }
        return searchesTimestamps
            && line.timestamp?.localizedCaseInsensitiveContains(search) == true
    }

    private func trimRetainedWindowIfNeeded() {
        guard lines.count > Self.maximumRetainedLines else { return }

        let overflow = lines.count - Self.maximumRetainedLines
        lines.removeSubrange(0..<overflow)
        guard let minimumRetainedID = lines.first?.id else {
            filteredLines.removeAll(keepingCapacity: true)
            return
        }

        let filteredOverflow = filteredLines
            .prefix(while: { $0.id < minimumRetainedID })
            .count
        if filteredOverflow > 0 {
            filteredLines.removeSubrange(0..<filteredOverflow)
        }
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
            let clock = ContinuousClock()
            var lastFlush = clock.now
            var batch: [LogLine] = []
            batch.reserveCapacity(50)

            for try await line in stream {
                guard generation == streamGeneration, !Task.isCancelled else { return }
                batch.append(line)
                let now = clock.now
                if lastFlush.duration(to: now) >= .milliseconds(50) || batch.count >= 50 {
                    receive(batch)
                    batch.removeAll(keepingCapacity: true)
                    lastFlush = now
                }
            }

            if !batch.isEmpty, generation == streamGeneration, !Task.isCancelled {
                receive(batch)
            }
            if generation == streamGeneration, !Task.isCancelled {
                connectionState = .ended
            }
        } catch {
            guard generation == streamGeneration else { return }
            if Task.isCancelled {
                connectionState = .idle
            } else {
                connectionState = .failed(error.localizedDescription)
            }
        }
    }
}
