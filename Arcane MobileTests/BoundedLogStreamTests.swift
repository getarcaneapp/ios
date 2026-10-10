import Arcane
import Foundation
import Network
import Synchronization
import Testing

@testable import Arcane_Mobile

@Suite("Bounded SDK log streams", .timeLimit(.minutes(1)))
struct BoundedLogStreamTests {
    @Test func usesScopedSessionAndPreservesStructuredLines() async throws {
        let server = try LogSocketServer()
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let stream = try await makeStream(server: server, session: session)
        let consumer = Task {
            do { return try await stream.makeAsyncIterator().next() } catch {
                Issue.record(error)
                throw error
            }
        }
        try await server.waitForConnection()
        let socket = try #require(await session.allTasks.first as? URLSessionWebSocketTask)
        let request = try #require(socket.originalRequest)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "proxy=session")
        #expect(socket.delegate != nil)
        #expect(socket.maximumMessageSize == RemoteDataLimits.maximumStreamLineBytes)
        try await server.send(#"{"message":"ready","seq":7,"level":"info","service":"api"}"#)
        let line = try #require(try await consumer.value)
        #expect(line.text == "ready")
        #expect(line.seq == 7)
        #expect(line.service == "api")
        #expect(server.connectionCount == 1)
        await expectSocketClosed(socket)
    }

    @Test func cancellationClosesSocketAndNeverReopensIterator() async throws {
        let server = try LogSocketServer()
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let stream = try await makeStream(server: server, session: session)
        let consumer = Task { () throws -> Void in
            let iterator = stream.makeAsyncIterator()
            do {
                _ = try await iterator.next()
                Issue.record("Expected cancellation")
            } catch is CancellationError {
            }
            #expect(try await iterator.next() == nil)
        }
        try await server.waitForConnection()
        let socket = try #require(await session.allTasks.first as? URLSessionWebSocketTask)
        consumer.cancel()
        try await consumer.value
        await expectSocketClosed(socket)
        #expect(server.connectionCount == 1)
    }

    @Test func exhaustedIteratorStaysExhausted() async throws {
        let server = try LogSocketServer()
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let stream = try await makeStream(server: server, session: session)
        let consumer = Task { () throws -> Void in
            let iterator = stream.makeAsyncIterator()
            do {
                #expect(try await iterator.next() == nil)
            } catch {
                // Foundation may report the transport closing before its cancellation status.
                let failure = error as NSError
                #expect(failure.domain == NSPOSIXErrorDomain && failure.code == 57)
            }
            #expect(try await iterator.next() == nil)
        }
        try await server.waitForConnection()
        let socket = try #require(await session.allTasks.first as? URLSessionWebSocketTask)
        socket.cancel(with: .normalClosure, reason: nil)
        try await consumer.value
        #expect(server.connectionCount == 1)
    }

    @Test func oversizedFrameFailsAndClosesSocket() async throws {
        let server = try LogSocketServer()
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let stream = try await makeStream(server: server, session: session)
        let consumer = Task { () throws -> Void in
            let iterator = stream.makeAsyncIterator()
            do {
                _ = try await iterator.next()
                Issue.record("Oversized log frame was accepted")
            } catch {
                #expect(!(error is CancellationError))
            }
            #expect(try await iterator.next() == nil)
        }
        try await server.waitForConnection()
        let socket = try #require(await session.allTasks.first as? URLSessionWebSocketTask)
        try await server.send(String(repeating: "x", count: RemoteDataLimits.maximumStreamLineBytes + 1))
        try await consumer.value
        await expectSocketClosed(socket)
        #expect(server.connectionCount == 1)
    }

    private func expectSocketClosed(_ socket: URLSessionWebSocketTask) async {
        for _ in 0..<500 {
            if socket.state == .canceling || socket.state == .completed { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(socket.state == .canceling || socket.state == .completed)
    }

    private func makeStream(server: LogSocketServer, session: URLSession) async throws -> BoundedLogStream {
        let client = ArcaneClient(
            configuration: .init(
                baseURL: try await server.baseURL(),
                tokenStore: InMemoryTokenStore(
                    tokens: .init(accessToken: "token", refreshToken: "refresh", expiresAt: .distantFuture)),
                urlSession: session,
                proxySession: LogProxySession()
            ))
        return client.boundedContainerLogs(envID: EnvironmentID(rawValue: "test"), id: "container", timestamps: true)
    }
}

private actor LogProxySession: ArcaneProxySession {
    private var receivedGenerations: [UInt64] = []
    func requestContext(for _: URL) -> ArcaneProxyRequestContext {
        .init(headers: ["Cookie": "proxy=session"], generation: 1)
    }
    func receive(response _: HTTPURLResponse, for _: URL, generation: UInt64) {
        receivedGenerations.append(generation)
    }
}

/// A loopback WebSocket peer exercises the SDK channel and actual URLSession cancellation.
private final class LogSocketServer: Sendable {
    private struct State {
        var connection: NWConnection?
        var ready = false
        var connectionCount = 0
    }
    private let state = Mutex(State())
    var connectionCount: Int { state.withLock { $0.connectionCount } }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "arcane.tests.websocket")

    init() throws {
        let parameters = NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.setClientRequestHandler(queue) { _, _ in
            .init(status: .accept, subprotocol: nil, additionalHeaders: [])
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            state.withLock {
                $0.connection = connection
                $0.connectionCount += 1
            }
            connection.stateUpdateHandler = { [weak self] status in
                if case .ready = status { self?.state.withLock { $0.ready = true } }
            }
            connection.start(queue: queue)
            Self.receiveControlFrames(connection)
        }
        listener.start(queue: queue)
    }

    private static func receiveControlFrames(_ connection: NWConnection) {
        connection.receiveMessage { _, context, _, error in
            guard error == nil else { return }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata,
                metadata.opcode == .close
            {
                connection.cancel()
            } else {
                receiveControlFrames(connection)
            }
        }
    }

    func baseURL() async throws -> URL {
        for _ in 0..<500 {
            if let port = listener.port, port.rawValue != 0 { return URL(string: "http://127.0.0.1:\(port.rawValue)")! }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LogServerError.listenerDidNotStart
    }

    func waitForConnection() async throws {
        for _ in 0..<500 {
            if state.withLock({ $0.ready }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LogServerError.connectionDidNotOpen
    }

    func send(_ text: String) async throws {
        try await waitForConnection()
        let connection = try #require(state.withLock { $0.connection })
        let context = NWConnection.ContentContext(
            identifier: "log", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: Data(text.utf8), contentContext: context,
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
        }
    }

    func stop() {
        state.withLock { $0.connection }?.cancel()
        listener.cancel()
    }
}

private enum LogServerError: Error {
    case listenerDidNotStart
    case connectionDidNotOpen
}
