import Foundation

/// Liveness for agents that keep every session in one shared database (Cursor's, Zed's and
/// VS Code's `state.vscdb`): while the app runs or anything holds the files open, Domovy cannot
/// tell which session is in use, so all of them count as live.
enum SharedDatabaseLiveness {
    /// - Parameters:
    ///   - what: how the reasons name the database ("Zed's thread databases").
    static func check(app: ProcessMatcher, files: [URL], what: String, processes: any RunningProcessLister,
                      openHandles: any OpenHandleChecker) async -> LiveCheckResult {
        var reasons: [String] = []
        let running = processes.blockingReasons([app])
        if !running.isEmpty {
            reasons += running
            reasons.append("Every \(app.appName) session lives in \(what), so Domovy treats all of them as in use while \(app.appName) runs.")
        }
        let status: LiveCheckResult.OpenHandleStatus
        if let holders = await openHandles.holders(of: files, includingMapped: true) {
            status = holders.isEmpty ? .clear : .open
            var seen = Set<Int32>()
            for holder in holders where seen.insert(holder.pid).inserted {
                reasons.append("\(holder.processName) (pid \(holder.pid)) has \(what) open, so Domovy cannot tell which session it uses.")
            }
        } else {
            status = .unavailable
        }
        return LiveCheckResult(isLive: !reasons.isEmpty, reasons: reasons, checkedSignals: ["\(app.appName) processes", "open file handles"], openHandles: status)
    }

    /// Before a plan writes to the database: an open-file check that could not run counts as live.
    static func forPlan(_ base: LiveCheckResult, what: String) -> LiveCheckResult {
        guard base.openHandles == .unavailable else { return base }
        return LiveCheckResult(isLive: true, reasons: base.reasons + ["Domovy could not check which processes have \(what) open, so it changes nothing."],
                               checkedSignals: base.checkedSignals, openHandles: base.openHandles)
    }

    /// The database and its journal files: cloned before an edit, and nothing may hold them open.
    static func files(of database: URL) -> [URL] {
        ["", "-wal", "-shm", "-journal"].map { database.deletingLastPathComponent().appendingPathComponent(database.lastPathComponent + $0) }
    }
}
