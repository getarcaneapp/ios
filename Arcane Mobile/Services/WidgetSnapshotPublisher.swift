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
    private var pendingTask: Task<Void, Never>?
    private static let debounce: Duration = .seconds(6)

    private init() {}

    /// Queue a snapshot for writing; coalesces bursts from the live stream.
    func schedule(_ snapshot: WidgetSnapshot) {
        latest = snapshot
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
        WidgetSnapshotStore.saveAndReloadIfChanged(latest)
    }

    /// Immediate signed-out snapshot (logout, demo ended, server cleared).
    func publishSignedOut() {
        pendingTask?.cancel()
        pendingTask = nil
        latest = nil
        WidgetSnapshotStore.saveAndReloadIfChanged(.signedOut(generatedAt: Date()))
    }
}
