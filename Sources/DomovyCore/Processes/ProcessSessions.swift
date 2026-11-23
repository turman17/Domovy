import Foundation

/// Maps agent processes to the sessions they serve, from the agents' own liveness signals:
/// Claude Code's `sessions/<pid>.json` and `daemon/roster.json` workers, and the Codex
/// `thread-writer-locks/<id>.lock` files a process holds open. Reads ids only.
public struct ProcessSessionResolver: Sendable {
    /// `~/.claude`.
    public let claudeCodeRoot: URL
    /// `~/.codex` or `$CODEX_HOME`.
    public let codexRoot: URL

    public init(claudeCodeRoot: URL, codexRoot: URL) {
        self.claudeCodeRoot = claudeCodeRoot.standardizedFileURL
        self.codexRoot = codexRoot.standardizedFileURL
    }

    public init(home: URL) {
        self.init(claudeCodeRoot: home.appendingPathComponent(".claude", isDirectory: true),
                  codexRoot: home.appendingPathComponent(".codex", isDirectory: true))
    }

    /// Session ids per pid, for the given agent processes.
    func sessions(for processes: [(process: RawProcess, agent: AgentKind)], source: any ProcessSource) -> [Int32: [String]] {
        var result: [Int32: [String]] = [:]
        let pids = Set(processes.filter { $0.agent == .claudeCode }.map(\.process.pid))
        if !pids.isEmpty {
            for (pid, id) in claudeCodeSessions() where pids.contains(pid) { result[pid, default: []].append(id) }
        }
        let me = source.currentUserID
        for entry in processes where entry.agent == .codex && entry.process.uid == me {
            let threads = codexThreads(in: source.openFiles(of: entry.process.pid) ?? [])
            if !threads.isEmpty { result[entry.process.pid, default: []] += threads }
        }
        return result
    }

    /// `(pid, sessionId)` from `sessions/*.json` and the roster.
    func claudeCodeSessions() -> [(Int32, String)] {
        var pairs: [(Int32, String)] = []
        let layout = ClaudeCodeLayout(root: claudeCodeRoot)
        for file in FileSystem.children(of: layout.sessions) where file.pathExtension == "json" {
            guard let object = Self.readJSON(file), let id = object["sessionId"] as? String,
                  let pid = Self.pid(object["pid"]) ?? Int32(file.deletingPathExtension().lastPathComponent) else { continue }
            pairs.append((pid, id.lowercased()))
        }
        if let roster = Self.readJSON(layout.daemonRoster), let workers = roster["workers"] as? [String: Any] {
            for case let worker as [String: Any] in workers.values {
                guard let id = worker["sessionId"] as? String, let pid = Self.pid(worker["pid"]) else { continue }
                pairs.append((pid, id.lowercased()))
            }
        }
        return pairs
    }

    /// Thread ids of the writer locks among `paths` that lie in this Codex home.
    func codexThreads(in paths: [String]) -> [String] {
        let locks = CodexLayout(root: codexRoot).threadWriterLocks.standardizedFileURL.path
        var real = locks
        if let resolved = realpath(locks, nil) {
            real = String(cString: resolved)
            free(resolved)
        }
        return paths.compactMap { path in
            let folder = (path as NSString).deletingLastPathComponent
            guard folder == locks || folder == real, path.hasSuffix(".lock") else { return nil }
            return ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        }
    }

    private static func pid(_ value: Any?) -> Int32? {
        switch value {
        case let int as Int: Int32(exactly: int)
        case let double as Double: Int32(exactly: double)
        default: nil
        }
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), data.count < 1_000_000 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
