import Arcane
import Foundation

/// Receive-only log stream that rejects oversized WebSocket frames before
/// decoding and uses a bounded delivery queue so a fast server cannot build an
/// unbounded backlog while SwiftUI is rendering.
nonisolated struct BoundedLogStream: AsyncSequence, Sendable {
    typealias Element = LogLine

    private let transport: ArcaneURLSessionTransport
    private let path: String
    private let query: [URLQueryItem]

    init(transport: ArcaneURLSessionTransport, path: String, query: [URLQueryItem]) {
        self.transport = transport
        self.path = path
        self.query = query + [URLQueryItem(name: "format", value: "json")]
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(transport: transport, path: path, query: query)
    }

    nonisolated final class Iterator: AsyncIteratorProtocol, @unchecked Sendable {
        private let transport: ArcaneURLSessionTransport
        private let path: String
        private let query: [URLQueryItem]
        private var channel: WebSocketChannel<Never, LogLine>?
        private var iterator: AsyncThrowingStream<LogLine, Error>.Iterator?

        init(transport: ArcaneURLSessionTransport, path: String, query: [URLQueryItem]) {
            self.transport = transport
            self.path = path
            self.query = query
        }

        func next() async throws -> LogLine? {
            try Task.checkCancellation()
            if iterator == nil {
                let request = try await transport.websocketRequest(path: path, query: query)
                let channel = WebSocketChannel<Never, LogLine>(
                    request: request,
                    encodeOutbound: { _ in fatalError("Log streams are receive-only") },
                    decodeInbound: { message in try Self.decode(message) }
                )
                self.channel = channel
                iterator = channel.messages(bufferingPolicy: .bufferingNewest(100)).makeAsyncIterator()
            }
            guard var current = iterator else { return nil }
            let value = try await current.next()
            iterator = current
            if value == nil {
                channel = nil
                iterator = nil
            }
            return value
        }

        private static func decode(_ message: URLSessionWebSocketTask.Message) throws -> LogLine {
            let data: Data
            switch message {
            case .string(let text):
                guard text.utf8.count <= RemoteDataLimits.maximumStreamLineBytes else {
                    throw RemoteDataLimitError.responseTooLarge(
                        maximumBytes: RemoteDataLimits.maximumStreamLineBytes
                    )
                }
                data = Data(text.utf8)
                if let wire = try? ArcaneJSON.makeDecoder().decode(WireLogLine.self, from: data) {
                    return try makeLogLine(from: wire)
                }
                return try makeLogLine(text: text)
            case .data(let frame):
                guard frame.count <= RemoteDataLimits.maximumStreamLineBytes else {
                    throw RemoteDataLimitError.responseTooLarge(
                        maximumBytes: RemoteDataLimits.maximumStreamLineBytes
                    )
                }
                let wire = try ArcaneJSON.makeDecoder().decode(WireLogLine.self, from: frame)
                return try makeLogLine(from: wire)
            @unknown default:
                throw ArcaneError.transport("Unsupported WebSocket log frame")
            }
        }

        private static func makeLogLine(from wire: WireLogLine) throws -> LogLine {
            try makeLogLine(
                text: wire.message,
                seq: wire.seq,
                level: wire.level,
                service: wire.service,
                timestamp: wire.timestamp
            )
        }

        private static func makeLogLine(
            text: String,
            seq: UInt64? = nil,
            level: String? = nil,
            service: String? = nil,
            timestamp: String? = nil
        ) throws -> LogLine {
            let value = DecodedLogLine(
                text: RemoteDataLimits.boundedText(
                    text,
                    maximumBytes: RemoteDataLimits.maximumStreamLineBytes
                ),
                seq: seq,
                level: level.map { RemoteDataLimits.boundedText($0, maximumBytes: 64) },
                service: service.map { RemoteDataLimits.boundedText($0, maximumBytes: 256) },
                timestamp: timestamp.map { RemoteDataLimits.boundedText($0, maximumBytes: 256) }
            )
            let data = try ArcaneJSON.makeEncoder().encode(value)
            return try ArcaneJSON.makeDecoder().decode(LogLine.self, from: data)
        }
    }
}

private nonisolated struct WireLogLine: Decodable, Sendable {
    let seq: UInt64?
    let level: String?
    let message: String
    let service: String?
    let timestamp: String?
}

private nonisolated struct DecodedLogLine: Encodable, Sendable {
    let text: String
    let seq: UInt64?
    let level: String?
    let service: String?
    let timestamp: String?
}

nonisolated extension ArcaneClient {
    func boundedContainerLogs(
        envID: EnvironmentID,
        id: String,
        timestamps: Bool
    ) -> BoundedLogStream {
        boundedLogs(
            path: rest.environmentPath(
                envID,
                "ws/containers/\(ArcaneAPIHelpers.escapedPathComponent(id))/logs"
            ),
            tail: "100",
            timestamps: timestamps
        )
    }

    func boundedProjectLogs(
        envID: EnvironmentID,
        projectID: String,
        timestamps: Bool
    ) -> BoundedLogStream {
        boundedLogs(
            path: rest.environmentPath(
                envID,
                "ws/projects/\(ArcaneAPIHelpers.escapedPathComponent(projectID))/logs"
            ),
            tail: "200",
            timestamps: timestamps
        )
    }

    private func boundedLogs(path: String, tail: String, timestamps: Bool) -> BoundedLogStream {
        BoundedLogStream(
            transport: transport,
            path: path,
            query: [
                URLQueryItem(name: "follow", value: "true"),
                URLQueryItem(name: "tail", value: tail),
                URLQueryItem(name: "timestamps", value: timestamps ? "true" : "false")
            ]
        )
    }
}
