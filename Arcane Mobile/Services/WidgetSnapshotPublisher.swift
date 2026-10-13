import Foundation

/// Debounced writer of the App-Group widget snapshot. The dashboard schedules
/// a publish whenever its stream data moves; sign-out/demo-end write a
/// signed-out snapshot immediately. All writes go through
/// `WidgetSnapshotStore`, which only spends a WidgetCenter reload on material
/// changes.
@MainActor
final class WidgetSnapshotPublisher {
    static let shared = WidgetSnapshotPublisher()

    private var latest: WidgetSnapshot?
    /// Last snapshot written by this process, or the persisted one (read
    /// from disk at most once), so callers don't decode the file per update.
    private var persisted: WidgetSnapshot?
    private var hasReadPersisted = false
    private var sessionIdentity: String?
    private var pendingTask: Task<Void, Never>?
    private static let debounce: Duration = .seconds(6)

    private init() {}

    /// The most recent snapshot queued or written, without touching disk
    /// after the first call.
    func lastKnownSnapshot() -> WidgetSnapshot? {
        if let latest { return latest }
        if !hasReadPersisted {
            persisted = WidgetSnapshotStore.load()
            hasReadPersisted = true
        }
        return persisted
    }

    /// Queue a snapshot for writing; coalesces bursts from the live stream.
    func schedule(_ snapshot: WidgetSnapshot) {
        latest = snapshot
        sessionIdentity = AppGroup.defaults?.string(forKey: AppGroup.Keys.sessionIdentity)
        guard pendingTask == nil else { return }
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Write whatever is queued right now (call when backgrounding).
    func flush() {
        pendingTask?.cancel()
        pendingTask = nil
        guard let latest else { return }
        self.latest = nil
        guard sessionIdentity == AppGroup.defaults?.string(forKey: AppGroup.Keys.sessionIdentity),
            latest.serverOrigin == IntentClientFactory.serverOrigin,
            latest.isDemo || SharedKeychain.credentialOrigin == latest.serverOrigin
        else { return }
        WidgetSnapshotStore.saveAndReloadIfChanged(latest)
        persisted = latest
        hasReadPersisted = true
    }

    /// Immediate signed-out snapshot (logout, demo ended, server cleared).
    func publishSignedOut() {
        pendingTask?.cancel()
        pendingTask = nil
        latest = nil
        let signedOut = WidgetSnapshot.signedOut(generatedAt: Date())
        WidgetSnapshotStore.saveAndReloadIfChanged(signedOut)
        persisted = signedOut
        hasReadPersisted = true
    }
}
