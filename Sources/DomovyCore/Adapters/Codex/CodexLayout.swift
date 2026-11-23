import Foundation

/// Paths inside `~/.codex` (or `$CODEX_HOME`), verified on Codex CLI 0.169 / app-server 0.171
/// (see docs/research/agent_storage_formats.md). Everything is relative to the injected root.
struct CodexLayout: Sendable {
    let root: URL

    var sessions: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    var archivedSessions: URL { root.appendingPathComponent("archived_sessions", isDirectory: true) }
    var sessionIndex: URL { root.appendingPathComponent("session_index.jsonl") }
    var history: URL { root.appendingPathComponent("history.jsonl") }
    var generatedImages: URL { root.appendingPathComponent("generated_images", isDirectory: true) }
    var attachments: URL { root.appendingPathComponent("attachments", isDirectory: true) }
    var worktrees: URL { root.appendingPathComponent("worktrees", isDirectory: true) }
    var threadWriterLocks: URL { root.appendingPathComponent("thread-writer-locks", isDirectory: true) }
    var stateDatabase: URL { root.appendingPathComponent(Self.stateDatabaseName) }
    var threadHistoryDatabase: URL { root.appendingPathComponent("thread_history_1.sqlite") }

    /// The diagnostic logs database and its `-wal` / `-shm` companions, which go together.
    func logsDatabaseFiles() -> [URL] {
        FileSystem.children(of: root).filter { $0.lastPathComponent.hasPrefix("logs_2.sqlite") }
    }

    /// The state database version this adapter understands.
    static let stateDatabaseName = "state_5.sqlite"

    /// Codex holds `thread-writer-locks/<id>.lock` open while a thread is loaded (verified with lsof).
    func writerLock(for id: String) -> URL {
        threadWriterLocks.appendingPathComponent("\(id).lock")
    }

    /// What Codex needs to run, and Domovy's never-touch list (CLAUDE.md safety rule 6).
    static let protectedRootEntries: Set<String> = [
        "auth.json", "auth.json.lock", "auth.lock", "config.toml", "rules", "skills", "plugins",
        "packages", "AGENTS.md", "keybindings.json", "installation_id", "app-server-daemon", "app-server-control",
        "memories", "vendor_imports",
    ]

    func isProtected(_ url: URL) -> Bool {
        guard let relative = FileSystem.relativePath(of: url, under: root) else { return false }
        guard let first = relative.split(separator: "/").first.map(String.init) else { return true } // the root itself
        return Self.protectedRootEntries.contains(first)
    }

    // MARK: Rollout naming

    /// A rollout file name, `rollout-<ts>-<uuid>[_<segment uuid>].jsonl[.zst]`.
    struct RolloutName: Hashable, Sendable {
        let threadID: String
        /// Rollouts named `<thread>_<uuid>` hold further segments of the same thread.
        let segmentID: String?
        let isCompressed: Bool
    }

    private static let uuid = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    private static let rolloutRegex = try? NSRegularExpression(
        pattern: "^rollout-\\d{4}-\\d{2}-\\d{2}T\\d{2}-\\d{2}-\\d{2}-(\(uuid))(?:_(\(uuid)))?\\.jsonl(\\.zst)?$"
    )

    static func rolloutName(_ name: String) -> RolloutName? {
        guard let regex = rolloutRegex,
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: name).map { String(name[$0]).lowercased() }
        }
        guard let thread = group(1) else { return nil }
        return RolloutName(threadID: thread, segmentID: group(2), isCompressed: group(3) != nil)
    }

    /// Every rollout file: `sessions/YYYY/MM/DD/*` and `archived_sessions/*`.
    func rolloutFiles() -> (active: [URL], archived: [URL]) {
        var active: [URL] = []
        for year in FileSystem.children(of: sessions) where FileSystem.isDirectory(year) {
            for month in FileSystem.children(of: year) where FileSystem.isDirectory(month) {
                for day in FileSystem.children(of: month) where FileSystem.isDirectory(day) {
                    active += FileSystem.children(of: day).filter { Self.rolloutName($0.lastPathComponent) != nil }
                }
            }
        }
        let archived = FileSystem.children(of: archivedSessions).filter { Self.rolloutName($0.lastPathComponent) != nil }
        return (active, archived)
    }

    // MARK: Probe

    /// Decides whether this layout is one we understand. Never guesses.
    func probe() -> AdapterStatus {
        guard FileSystem.exists(root) else { return .notInstalled }
        guard FileSystem.isDirectory(sessions) else {
            return .readOnly(reason: "Expected a sessions/ folder inside \(root.lastPathComponent) and found none.")
        }
        let states = FileSystem.children(of: root).map(\.lastPathComponent).filter { $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }
        if !states.isEmpty, !states.contains(Self.stateDatabaseName) {
            return .readOnly(reason: "Codex uses a state database Domovy does not know (\(states.joined(separator: ", "))). This may be a newer Codex; nothing will be changed until it is understood.")
        }
        let unexpected = unexpectedRolloutFiles()
        if unexpected > 0 {
            return .readOnly(reason: "Found \(unexpected) session file\(unexpected == 1 ? "" : "s") with a name or place Domovy does not recognise. This may be a newer Codex layout; nothing will be changed until it is understood.")
        }
        return .ready
    }

    /// Files under `sessions/` that are not rollouts at `YYYY/MM/DD/`, and odd files in `archived_sessions/`.
    private func unexpectedRolloutFiles() -> Int {
        func isHidden(_ url: URL) -> Bool { url.lastPathComponent.hasPrefix(".") }
        func digits(_ url: URL, _ count: Int) -> Bool {
            let name = url.lastPathComponent
            return name.count == count && name.allSatisfy(\.isNumber)
        }
        var unexpected = 0
        for year in FileSystem.children(of: sessions) where !isHidden(year) {
            guard FileSystem.isDirectory(year), digits(year, 4) else { unexpected += 1; continue }
            for month in FileSystem.children(of: year) where !isHidden(month) {
                guard FileSystem.isDirectory(month), digits(month, 2) else { unexpected += 1; continue }
                for day in FileSystem.children(of: month) where !isHidden(day) {
                    guard FileSystem.isDirectory(day), digits(day, 2) else { unexpected += 1; continue }
                    unexpected += FileSystem.children(of: day).filter { !isHidden($0) && Self.rolloutName($0.lastPathComponent) == nil }.count
                }
            }
        }
        unexpected += FileSystem.children(of: archivedSessions).filter { !isHidden($0) && Self.rolloutName($0.lastPathComponent) == nil }.count
        return unexpected
    }
}
