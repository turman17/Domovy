import Foundation

/// Reads Claude Code's own liveness files. Each running CLI writes `sessions/<pid>.json`
/// (removed on exit); background workers appear in `daemon/roster.json`. A marker whose
/// pid no longer exists is stale (left behind by a crash) and is ignored.
struct ClaudeCodeLiveness: Sendable {
    let layout: ClaudeCodeLayout
    let openHandles: any OpenHandleChecker
    let processes: any ProcessProbe

    /// The liveness files as they are now: one marker per running CLI, one per roster worker.
    struct Markers: Sendable {
        struct Marker: Sendable {
            /// `sessions/<pid>.json`, or `nil` for a roster worker.
            let file: URL?
            /// Lowercased.
            let sessionID: String
            let pid: Int32?
        }

        let sessions: [Marker]
        let workers: [Marker]
    }

    func check(sessionID: String, artifactURLs: [URL]) async -> LiveCheckResult {
        let reasons = markerReasons(sessionID: sessionID, markers: readMarkers())
        return result(markerReasons: reasons, holders: await openHandles.holders(of: artifactURLs))
    }

    /// Reads `sessions/*.json` and `daemon/roster.json`. A listing reads them once for all its
    /// sessions; a single check reads them fresh.
    func readMarkers() -> Markers {
        var sessions: [Markers.Marker] = []
        for file in FileSystem.children(of: layout.sessions) where file.pathExtension == "json" {
            guard let object = Self.readJSON(file), let id = object["sessionId"] as? String else { continue }
            let pid = Self.pid(object["pid"]) ?? Int32(file.deletingPathExtension().lastPathComponent)
            sessions.append(.init(file: file, sessionID: id.lowercased(), pid: pid))
        }
        var workers: [Markers.Marker] = []
        if let roster = Self.readJSON(layout.daemonRoster), let all = roster["workers"] as? [String: Any] {
            for case let worker as [String: Any] in all.values {
                guard let id = worker["sessionId"] as? String else { continue }
                workers.append(.init(file: nil, sessionID: id.lowercased(), pid: Self.pid(worker["pid"])))
            }
        }
        return Markers(sessions: sessions, workers: workers)
    }

    /// Reasons the liveness files give for `sessionID`; markers of a gone pid are stale.
    func markerReasons(sessionID: String, markers: Markers) -> [String] {
        var reasons: [String] = []
        for marker in markers.sessions where marker.sessionID == sessionID {
            let name = marker.file?.lastPathComponent ?? ""
            if let pid = marker.pid, !processes.isRunning(pid) {
                Log.liveness.info("Ignoring stale marker \(name, privacy: .private): pid \(pid, privacy: .public) is gone")
                continue
            }
            let pidText = marker.pid.map { " (pid \($0))" } ?? ""
            reasons.append("Claude Code reports this session as running\(pidText). Quit that Claude Code session first.")
            Log.liveness.info("Session \(sessionID, privacy: .public) is live via \(name, privacy: .private)")
        }
        for worker in markers.workers where worker.sessionID == sessionID {
            if let pid = worker.pid, !processes.isRunning(pid) {
                Log.liveness.info("Ignoring stale roster worker: pid \(pid, privacy: .public) is gone")
                continue
            }
            reasons.append("A Claude Code background worker is attached to this session. Stop it with `claude rm` first.")
        }
        return reasons
    }

    /// The check's result from the marker reasons and the open-file holders (`nil`: the
    /// handle check could not run).
    func result(markerReasons: [String], holders: [OpenHandleHolder]?) -> LiveCheckResult {
        var reasons = markerReasons
        let signals = ["sessions/*.json", "daemon/roster.json", "open file handles"]
        let status: LiveCheckResult.OpenHandleStatus
        if let holders {
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
