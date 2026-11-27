import Foundation
import os

/// The executor's answer to "does another process hold these files open?", from one process
/// snapshot (open descriptors and mapped files of every process) that the checks of a batch
/// share while it is young.
///
/// Safety (rule 2): no user-space check is atomic with the rename or swap that follows it, so
/// every check has a window in which a process can open the file unseen. With a fresh snapshot
/// per check that window is the walk itself (about 100 ms over ~700 processes; a process looked
/// at first is that stale when the walk ends) plus the time until the swap. Here every check is
/// answered from a snapshot whose walk *started* at most `maxAge` before the check, and an
/// older one is retaken, so the window is at most `maxAge` plus the time until the swap: a
/// process that opened the file longer than `maxAge` before a check is always seen, also when
/// it opened it after the batch began. Inside the window the other guards stay: in-place
/// rewrites give way when the file's mtime or size changed before the swap, and a moved file
/// stays whole in the Trash or quarantine for undo. A snapshot that cannot be taken is never
/// replaced by an older one: the check fails closed.
final class OpenFileSnapshots: Sendable {
    /// About two full snapshot walks: retaking costs at most ~40% of a long batch, a short one
    /// (most deletes and archives) takes a single snapshot.
    static let defaultMaxAge: Duration = .milliseconds(250)

    let maxAge: Duration
    private let clock: @Sendable () -> ContinuousClock.Instant
    private let latest = OSAllocatedUnfairLock<Snapshot?>(initialState: nil)

    private struct Snapshot: Sendable {
        let holders: [OpenHandleHolder]
        let startedAt: ContinuousClock.Instant
    }

    init(maxAge: Duration = OpenFileSnapshots.defaultMaxAge, clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.maxAge = maxAge
        self.clock = clock
    }

    /// Holders of `files` (or of something below them), `nil` when no snapshot could be taken.
    func holders(of files: [URL], from lister: any RunningProcessLister) -> [OpenHandleHolder]? {
        guard !files.isEmpty else { return [] }
        let now = clock()
        if let cached = latest.withLock({ $0 }), now - cached.startedAt <= maxAge {
            return matchOpenPaths(cached.holders, against: files)
        }
        let startedAt = clock()
        guard let holders = lister.openFileSnapshot() else {
            latest.withLock { $0 = nil }
            return nil
        }
        latest.withLock { $0 = Snapshot(holders: holders, startedAt: startedAt) }
        return matchOpenPaths(holders, against: files)
    }
}
