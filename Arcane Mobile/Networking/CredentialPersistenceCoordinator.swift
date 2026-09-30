import Foundation
import Arcane

/// A synchronous retirement fence shared by every client in an authentication attempt.
nonisolated final class CredentialLease: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var allowsClear = true

    var isActive: Bool { lock.withLock { active } }
    var canClear: Bool { lock.withLock { allowsClear } }

    func retire(allowClear: Bool = false) {
        lock.withLock {
            active = false
            allowsClear = allowClear
        }
    }

    func whileActive(_ operation: () -> Void) throws {
        try lock.withLock {
            guard active else { throw CancellationError() }
            operation()
        }
    }
}

/// Serializes mutations from retired and replacement clients. A suspended old
/// write is removed before a replacement write can persist its credentials.
actor CredentialPersistenceCoordinator {
    private var tail: Task<Void, Error>?

    func save(
        _ tokens: TokenPair,
        to store: any TokenStore,
        lease: CredentialLease,
        bind: @escaping @Sendable () -> Void
    ) async throws {
        let previous = tail
        let task = Task {
            _ = try? await previous?.value
            guard lease.isActive else { throw CancellationError() }
            try await store.saveTokens(tokens)
            guard lease.isActive else {
                if try await store.loadTokens() == tokens { try await store.clearTokens() }
                throw CancellationError()
            }
            do { try lease.whileActive(bind) }
            catch {
                if try await store.loadTokens() == tokens { try await store.clearTokens() }
                throw error
            }
        }
        tail = task
        try await task.value
    }

    func clear(
        stores: [any TokenStore],
        lease: CredentialLease,
        unbind: @escaping @Sendable () -> Void
    ) async throws {
        let previous = tail
        let task = Task {
            _ = try? await previous?.value
            guard lease.canClear else { throw CancellationError() }
            var firstError: Error?
            for store in stores {
                guard lease.canClear else { throw CancellationError() }
                do { try await store.clearTokens() }
                catch { if firstError == nil { firstError = error } }
            }
            if lease.canClear { unbind() }
            if let firstError { throw firstError }
        }
        tail = task
        try await task.value
    }
}
