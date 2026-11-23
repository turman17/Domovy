import Foundation

/// Reads Claude Code's own liveness files. Each running CLI writes `sessions/<pid>.json`
/// (removed on exit); background workers appear in `daemon/roster.json`. A marker whose
/// pid no longer exists is stale (left behind by a crash) and is ignored.
struct ClaudeCodeLiveness: Sendable {
    let layout: ClaudeCodeLayout
    let openHandles: any OpenHandleChecker
    let processes: any ProcessProbe

    func check(sessionID: String, artifactURLs: [URL]) async -> LiveCheckResult {
        var reasons: [String] = []
        var signals: [String] = []

        signals.append("sessions/*.json")
        for file in FileSystem.children(of: layout.sessions) where file.pathExtension == "json" {
            guard let object = Self.readJSON(file), let id = object["sessionId"] as? String, id.lowercased() == sessionID else { continue }
            let pid = Self.pid(object["pid"]) ?? Int32(file.deletingPathExtension().lastPathComponent)
            if let pid, !processes.isRunning(pid) {
                Log.liveness.info("Ignoring stale marker \(file.lastPathComponent, privacy: .private): pid \(pid, privacy: .public) is gone")
                continue
            }
            let pidText = pid.map { " (pid \($0))" } ?? ""
            reasons.append("Claude Code reports this session as running\(pidText). Quit that Claude Code session first.")
            Log.liveness.info("Session \(sessionID, privacy: .public) is live via \(file.lastPathComponent, privacy: .private)")
        }

        signals.append("daemon/roster.json")
        if let roster = Self.readJSON(layout.daemonRoster), let workers = roster["workers"] as? [String: Any] {
            for case let worker as [String: Any] in workers.values {
                guard let id = worker["sessionId"] as? String, id.lowercased() == sessionID else { continue }
                if let pid = Self.pid(worker["pid"]), !processes.isRunning(pid) {
                    Log.liveness.info("Ignoring stale roster worker: pid \(pid, privacy: .public) is gone")
                    continue
                }
                reasons.append("A Claude Code background worker is attached to this session. Stop it with `claude rm` first.")
            }
        }

        signals.append("open file handles")
        let status: LiveCheckResult.OpenHandleStatus
        if let holders = await openHandles.holders(of: artifactURLs) {
            status = holders.isEmpty ? .clear : .open
            var seen = Set<Int32>()
            for holder in holders where seen.insert(holder.pid).inserted {
                reasons.append("\(holder.processName) (pid \(holder.pid)) has a file of this session open.")
            }
        } else {
            status = .unavailable
        }

        return LiveCheckResult(isLive: !reasons.isEmpty, reasons: reasons, checkedSignals: signals, openHandles: status)
    }

    private static func pid(_ value: Any?) -> Int32? {
        switch value {
        case let int as Int: Int32(exactly: int)
        case let double as Double: Int32(exactly: double)
        default: nil
        }
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
