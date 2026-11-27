import CryptoKit
import Foundation

/// Paths of Kimi CLI, read from MoonshotAI/kimi-cli@9ab1286b (docs/research/agent_storage_formats.md,
/// Q9; not verified on a real install). Permalink base:
/// https://github.com/MoonshotAI/kimi-cli/blob/9ab1286b8fe4e6bcd116949a27ce5e0ac3389c82/src/kimi_cli/
///
/// - The share folder is `~/.kimi` (`KIMI_SHARE_DIR` moves it; share.py). `kimi.json` lists
///   `work_dirs[{path, kaos, last_session_id}]` (metadata.py#L17-L56).
/// - A session is the folder `sessions/<md5(work dir)>/<uuid>/` (metadata.py#L33-L40, session.py#L145):
///   `context.jsonl` (rotated to `context_<n>.jsonl`), `wire.jsonl`, `state.json` and `subagents/`,
///   `tasks/`, `notifications/`, `uploads/`. Kimi's own delete removes that folder (session.py#L99-L104,
///   web/api/sessions.py#L565-L583). Its archive is only a flag in `state.json` (web/api/sessions.py#L586-L613).
/// - There is no lock or pid file for a running session (only OAuth credential locks), so a delete
///   needs Kimi quit.
struct KimiLayout: Sendable {
    let root: URL

    var sessions: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    var metadata: URL { root.appendingPathComponent("kimi.json") }

    /// Entries Kimi needs to run or keeps for the user (config.py, metadata.py, cli/mcp.py, auth/).
    static let protectedEntries: Set<String> = [
        "config.toml", "config.json", "config.json.bak", "kimi.json", "mcp.json", "credentials", "mcp-oauth", "device_id",
        "plugins", "user-history", "bin", "imported_sessions", "kimi_code_tips.json", "latest_version.txt", "skipped_version.txt",
    ]

    func isProtected(_ url: URL) -> Bool {
        guard let relative = FileSystem.relativePath(of: url, under: root) else { return false }
        let parts = relative.split(separator: "/").map(String.init)
        guard let first = parts.first else { return true }
        if first == "sessions" { return parts.count < 3 }
        return Self.protectedEntries.contains(first)
    }

    /// `md5(str(path))` of each work dir, mapped back to its path (metadata.py#L33-L40).
    func workDirs() -> [String: String] {
        guard let dirs = FileSessions.object(metadata)?["work_dirs"] as? [[String: Any]] else { return [:] }
        var result: [String: String] = [:]
        for dir in dirs {
            guard let path = dir["path"] as? String else { continue }
            let kaos = (dir["kaos"] as? String) ?? "local"
            let hash = Self.md5(path)
            result[kaos == "local" ? hash : "\(kaos)_\(hash)"] = path
        }
        return result
    }

    static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func isSessionID(_ name: String) -> Bool { UUID(uuidString: name) != nil }

    /// Session folders: a uuid with `context.jsonl` or `wire.jsonl` inside.
    func sessionFolders() -> [URL] {
        FileSystem.children(of: sessions).filter(FileSystem.isDirectory).flatMap { hash in
            FileSystem.children(of: hash).filter { folder in
                Self.isSessionID(folder.lastPathComponent) && FileSystem.isDirectory(folder)
                    && (FileSystem.exists(folder.appendingPathComponent("context.jsonl")) || FileSystem.exists(folder.appendingPathComponent("wire.jsonl")))
            }.map(\.standardizedFileURL)
        }
    }

    /// Flat `sessions/<hash>/<id>.jsonl` from older versions; Kimi moves each into its folder the
    /// next time it lists sessions there (session.py#L309-L318).
    func legacyFiles() -> [URL] {
        FileSystem.children(of: sessions).filter(FileSystem.isDirectory).flatMap { hash in
            FileSystem.children(of: hash).filter { $0.pathExtension == "jsonl" && Self.isSessionID($0.deletingPathExtension().lastPathComponent) }
        }
    }

    func probe() -> AdapterStatus {
        guard FileSystem.isDirectory(root) else { return .notInstalled }
        if FileSystem.exists(sessions), !FileSystem.isDirectory(sessions) {
            return .readOnly(reason: "~/.kimi/sessions is not a folder, which Domovy does not know from any Kimi CLI version.")
        }
        for folder in sessionFolders().prefix(50) {
            let state = folder.appendingPathComponent("state.json")
            guard FileSystem.exists(state) else { continue }
            guard let object = FileSessions.object(state), (object["version"] as? Int).map({ $0 == 1 }) ?? true else {
                return .readOnly(reason: "A Kimi CLI session has a state.json Domovy does not know (version 1 is known), so it only lists what it can read.")
            }
        }
        return .ready
    }
}

/// Adapter for Kimi CLI. Delete moves the session folder to the Trash or the quarantine, as Kimi's
/// own delete removes it, with Kimi quit. Archive compresses the session's files in place; Kimi's
/// own archive flag (`state.json` `archived`) is shown as the archived status but never written.
public struct KimiAdapter: AgentAdapter {
    public let kind: AgentKind = .kimi
    public let root: URL

    let layout: KimiLayout
    let openHandles: any OpenHandleChecker
    let processes: any RunningProcessLister

    /// `kimi` / `kimi-cli` are Python entry points (pyproject.toml#L79-L81); the CLI sets its process
    /// title to "Kimi Code" and workers to `kimi-code-worker` (cli/__init__.py#L371-L373, #L1038).
    public static let processMatcher = ProcessMatcher(
        appName: "Kimi CLI", names: ["kimi", "kimi-cli", "kimi-code"], prefixes: ["kimi-code-"],
        quitAdvice: "Quit Kimi CLI (and `kimi web`) to change its sessions.", argumentMarkers: ["kimi_cli", "/bin/kimi", "Kimi Code"]
    )

    public init(kimiHome: URL, openHandles: any OpenHandleChecker = LibprocOpenHandleChecker(),
                processes: any RunningProcessLister = LibprocProcessLister()) {
        self.root = kimiHome.standardizedFileURL
        self.layout = KimiLayout(root: self.root)
        self.openHandles = openHandles
        self.processes = processes
    }

    public init(home: URL) {
        self.init(kimiHome: home.appendingPathComponent(".kimi", isDirectory: true), openHandles: LibprocOpenHandleChecker.shared)
    }

    // MARK: AgentAdapter

    public func status() async -> AdapterStatus { layout.probe() }

    public func sessions() async throws -> [Session] {
        if case .notInstalled = layout.probe() { throw AdapterError.notInstalled(kind) }
        let dirs = layout.workDirs()
        let folders = layout.sessionFolders()
        let holders = await openHandleHolders(of: folders.map { [$0] }, checker: openHandles)
        return zip(folders, holders).map { folder, holders in
            makeSession(folder, project: dirs[folder.deletingLastPathComponent().lastPathComponent], live: liveness(holders))
        }
        .sorted { $0.lastActive > $1.lastActive }
    }

    public func artifacts(of session: Session) async throws -> [Artifact] {
        let folder = try locate(session)
        return [Artifact(url: folder, kind: .folder, sizeBytes: FileSystem.size(of: folder),
                         note: "Session folder: context, wire log, state, subagents")]
    }

    public func liveCheck(_ session: Session) async throws -> LiveCheckResult {
        guard let result = await liveChecks(for: [session]).first else { throw AdapterError.sessionNotFound(session.id) }
        return try result.get()
    }

    public func liveChecks(for sessions: [Session]) async -> [Result<LiveCheckResult, any Error>] {
        await FileSessions.liveChecks(for: sessions, checker: openHandles, locate: locate, files: { [$0] }, liveness: { liveness($1) })
    }

    public func deletePlan(for session: Session, destination: Destination = .trash) async throws -> Plan {
        guard let planned = await deletePlans(for: [session], destination: destination).first else { throw AdapterError.sessionNotFound(session.id) }
        return try planned.result.get()
    }

    public func deletePlans(for sessions: [Session], destination: Destination) async -> [PlannedSession] {
        let writable = Result { try requireWritable() }
        let blocking = processes.blockingReasons([Self.processMatcher])
        return await FileSessions.plans(
            for: sessions, checker: openHandles, locate: locate, files: { [$0] }, liveness: { liveness($1) },
            finish: { session, folder, live in
                try writable.get()
                if layout.isProtected(folder) { throw AdapterError.protectedPathInPlan(folder) }
                let move = FileMove(source: folder, kind: .folder, sizeBytes: FileSystem.size(of: folder),
                                    note: "Session folder: context, wire log, state, subagents")
                var remarks = ["Kimi CLI deletes a session by removing its folder. Domovy does the same while Kimi CLI is quit, so the folder can come back with undo."]
                if lastSessionIDs().contains(session.id) {
                    remarks.append("kimi.json still names this as the last session of its folder; Domovy does not edit that file. `kimi --continue` there then starts a new session.")
                }
                return Plan(agent: kind, sessionID: session.id, action: .delete, destination: destination, moves: [move], indexEdits: [],
                            remarks: remarks, mustNotBeRunning: [Self.processMatcher],
                            liveCheck: FileSessions.forPlan(live, blocking: blocking, app: "Kimi CLI"), scope: scope)
            })
    }

    public func archivePlan(for session: Session) async throws -> Plan {
        guard let planned = await archivePlans(for: [session]).first else { throw AdapterError.sessionNotFound(session.id) }
        return try planned.result.get()
    }

    /// Compresses the session's files in place; Kimi reads them unchanged.
    public func archivePlans(for sessions: [Session]) async -> [PlannedSession] {
        let writable = Result { try requireWritable() }
        let blocking = processes.blockingReasons([Self.processMatcher])
        return await FileSessions.plans(
            for: sessions, checker: openHandles, locate: locate, files: { [$0] }, liveness: { liveness($1) },
            finish: { session, folder, live in
                try writable.get()
                let artifact = Artifact(url: folder, kind: .folder, sizeBytes: 0, note: "Session file")
                let compressions = try FileSessions.compressions(of: [artifact], isProtected: layout.isProtected)
                    .filter { $0.file.lastPathComponent != "state.json" }
                return Plan(agent: kind, sessionID: session.id, action: .archive, destination: nil, moves: [], indexEdits: [],
                            compressions: compressions,
                            remarks: ["Kimi CLI's own archive is a flag in state.json that only hides the session in `kimi web`. Domovy compresses the files instead and leaves state.json as it is."],
                            mustNotBeRunning: [Self.processMatcher],
                            liveCheck: FileSessions.forPlan(live, blocking: blocking, app: "Kimi CLI"), scope: scope)
            })
    }

    public func transcript(of session: Session, limit: Int, masking findings: [SecretFinding]) async throws -> Transcript {
        let folder = try locate(session)
        return try FileSessions.readJSONLines(of: folder.appendingPathComponent("context.jsonl"), maxMessages: limit, masking: findings) { record, index in
            Self.message(record, index: index)
        }
    }

    public func transcriptPage(of session: Session, limit: Int, before cursor: TranscriptCursor?, masking findings: [SecretFinding]) async throws -> Transcript {
        let folder = try locate(session)
        return try FileSessions.readJSONLinesPage(of: folder.appendingPathComponent("context.jsonl"), limit: limit, before: cursor, masking: findings) { record, index in
            Self.message(record, index: index)
        }
    }

    // MARK: Sessions

    private func makeSession(_ folder: URL, project: String?, live: LiveCheckResult) -> Session {
        let state = FileSessions.object(folder.appendingPathComponent("state.json")) ?? [:]
        let context = folder.appendingPathComponent("context.jsonl")
        let wire = folder.appendingPathComponent("wire.jsonl")
        let flagged = state["archived"] as? Bool == true
        let compressed = APFSCompression.isCompressed(context)
        let lastActive = [context, wire].compactMap(FileSystem.modificationDate).max() ?? .distantPast
        return Session(
            id: folder.lastPathComponent,
            agent: kind,
            title: FileSessions.title(state["custom_title"] as? String) ?? firstPrompt(wire: wire, context: context),
            projectPath: project,
            lastActive: lastActive,
            sizeBytes: FileSystem.size(of: folder),
            status: live.isLive ? .live : (flagged || compressed) ? .archived : .idle,
            expiresAt: nil,
            transcriptURL: FileSystem.exists(context) ? context : wire,
            isArchived: flagged || compressed
        )
    }

    /// Kimi's fallback title: the first `TurnBegin`'s `user_input` in `wire.jsonl` (session.py#L106-L128),
    /// else the first user message of `context.jsonl`.
    private func firstPrompt(wire: URL, context: URL) -> String? {
        for record in FileSessions.records(in: wire) {
            guard let message = record["message"] as? [String: Any], message["type"] as? String == "TurnBegin" else { continue }
            if let title = FileSessions.title(FileSessions.text(of: (message["payload"] as? [String: Any])?["user_input"])) { return title }
        }
        let user = FileSessions.records(in: context).first { $0["role"] as? String == "user" }
        return FileSessions.title(FileSessions.text(of: user?["content"]))
    }

    /// `{role, content, tool_calls?}` with content a string or `[{type: text, text}]`; rows whose
    /// role starts with `_` are Kimi's bookkeeping (soul/context.py#L99-L248).
    static func message(_ record: [String: Any], index: Int) -> TranscriptMessage? {
        let role: TranscriptMessage.Role
        switch record["role"] as? String {
        case "user": role = .user
        case "assistant": role = .assistant
        default: return nil
        }
        var blocks: [TranscriptMessage.Block] = []
        if let text = FileSessions.text(of: record["content"]) { blocks.append(.text(text)) }
        for case let call as [String: Any] in record["tool_calls"] as? [Any] ?? [] {
            blocks.append(.toolCall(((call["function"] as? [String: Any])?["name"] as? String) ?? "Tool"))
        }
        guard !blocks.isEmpty else { return nil }
        return TranscriptMessage(id: "k\(index)", role: role, timestamp: nil, blocks: blocks)
    }

    private func lastSessionIDs() -> Set<String> {
        let dirs = FileSessions.object(layout.metadata)?["work_dirs"] as? [[String: Any]] ?? []
        return Set(dirs.compactMap { $0["last_session_id"] as? String })
    }

    // MARK: Liveness

    /// Kimi writes no marker for a running session; only an open file of it says so here, and
    /// plans also need Kimi quit.
    private func liveness(_ holders: [OpenHandleHolder]?) -> LiveCheckResult {
        FileSessions.liveness(markers: [], holders: holders, signals: [])
    }

    // MARK: Guards

    private func locate(_ session: Session) throws -> URL {
        let folder = session.transcriptURL.standardizedFileURL.deletingLastPathComponent()
        guard session.agent == kind, KimiLayout.isSessionID(session.id), folder.lastPathComponent == session.id,
              FileSystem.relativePath(of: folder, under: layout.sessions)?.split(separator: "/").count == 2,
              FileSystem.isDirectory(folder) else {
            throw AdapterError.sessionNotFound(session.id)
        }
        return folder
    }

    private func requireWritable() throws {
        switch layout.probe() {
        case .readOnly(let reason): throw AdapterError.readOnly(kind, reason: reason)
        case .notInstalled: throw AdapterError.notInstalled(kind)
        case .ready: break
        }
    }
}

extension KimiAdapter {
    public func footprint() async throws -> Footprint {
        guard FileSystem.isDirectory(root) else { throw AdapterError.notInstalled(kind) }
        var builder = FootprintBuilder(agent: kind, root: root)
        builder.add("Settings and sign-in", KimiLayout.protectedEntries.sorted().map { root.appendingPathComponent($0) }, reveal: root, .keep,
                    "Kimi CLI needs these to run. Domovy never removes them.")
        builder.add("Older sessions", layout.legacyFiles(), reveal: layout.sessions, .consequences,
                    "Sessions saved by older Kimi CLI versions as one file. Kimi moves each into its own folder the next time it lists sessions there.")
        let count = layout.sessionFolders().count
        builder.add("Sessions", layout.sessions, .consequences,
                    "\(count) \(count == 1 ? "session" : "sessions"). Delete or archive them one by one in Sessions.", guidance: .manageInSessions)
        builder.add("Logs", root.appendingPathComponent("logs", isDirectory: true), .safe, "Diagnostic logs. Remove them while Kimi CLI is quit.")
        builder.add("Other", builder.unclaimedChildren(of: root), reveal: root, .keep, "Caches and state Domovy does not manage yet. Left alone.")
        return builder.build()
    }
}
