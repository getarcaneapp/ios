import Arcane
import Foundation

/// Interactive terminal channel with bounded inbound frames and queue depth.
/// Outbound input remains lossless; only an overproducing remote server's
/// unread output is coalesced.
nonisolated final class BoundedTerminalSession: Sendable {
    private let channel: WebSocketChannel<String, Data>
    let output: AsyncThrowingStream<Data, Error>

    private init(channel: WebSocketChannel<String, Data>) {
        self.channel = channel
        output = channel.messages(bufferingPolicy: .bufferingNewest(100))
    }

    static func connect(
        transport: ArcaneURLSessionTransport,
        path: String,
        shell: String
    ) async throws -> BoundedTerminalSession {
        let request = try await transport.websocketRequest(
            path: path,
            query: [URLQueryItem(name: "shell", value: shell)]
        )
        let channel = WebSocketChannel<String, Data>(
            request: request,
            encodeOutbound: { .string($0) },
            decodeInbound: { message in
                let data: Data
                switch message {
                case .string(let text):
                    guard text.utf8.count <= RemoteDataLimits.maximumTerminalFrameBytes else {
                        throw RemoteDataLimitError.responseTooLarge(
                            maximumBytes: RemoteDataLimits.maximumTerminalFrameBytes
                        )
                    }
                    data = Data(text.utf8)
                case .data(let frame):
                    guard frame.count <= RemoteDataLimits.maximumTerminalFrameBytes else {
                        throw RemoteDataLimitError.responseTooLarge(
                            maximumBytes: RemoteDataLimits.maximumTerminalFrameBytes
                        )
                    }
                    data = frame
                @unknown default:
                    throw ArcaneError.transport("Unsupported terminal frame")
                }
                return data
            }
        )
        return BoundedTerminalSession(channel: channel)
    }

    func send(_ text: String) async throws {
        try await channel.send(RemoteDataLimits.boundedText(text, maximumBytes: 16 * 1_024))
    }

    func close() async {
        await channel.close()
    }
}

nonisolated extension ArcaneClient {
    func boundedExec(
        envID: EnvironmentID,
        id: String,
        shell: String = "/bin/sh"
    ) async throws -> BoundedTerminalSession {
        let path = rest.environmentPath(
            envID,
            "ws/containers/\(ArcaneAPIHelpers.escapedPathComponent(id))/terminal"
        )
        return try await BoundedTerminalSession.connect(
            transport: transport,
            path: path,
            shell: shell
        )
    }
}
