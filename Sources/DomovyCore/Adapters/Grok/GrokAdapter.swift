import Foundation

/// The community Grok CLI (`grok-dev`), read from superagent-ai/grok-cli@fb97af83
/// (docs/research/agent_storage_formats.md, Q9; not verified on a real install). Permalink base:
/// https://github.com/superagent-ai/grok-cli/blob/fb97af83f06dca873281d60168430f06c8de6324/
///
/// - Everything is in `~/.grok/grok.db`, WAL mode, `foreign_keys = ON` (src/storage/db.ts#L23-L40).
/// - `PRAGMA user_version` 1–3 (src/storage/migrations.ts#L3-L26). `sessions(id, workspace_id, title,
///   cwd_at_start, cwd_last, status 'active'|'archived', created_at, updated_at, …)` belong to
///   `workspaces(id, canonical_path, …)`; `messages`, `tool_calls`, `usage_events` and `compactions`
///   reference the session and `tool_results` its tool calls, all `ON DELETE CASCADE`
///   (migrations.ts#L28-L134, src/types/index.ts#L245).
/// - The CLI has no delete of its own (no `DELETE` statement in src/). Domovy deletes the session's
///   rows itself, children first, with Grok quit and the database cloned first.
/// - Keep `user-settings.json` and above all `wallet.json` (src/wallet/manager.ts).
/// - xAI's official Grok Build also installs a `grok` binary; its storage is unknown. Domovy goes by
///   the `grok.db` schema, not the command name.
struct GrokLayout: Sendable {
    let root: URL

    var database: URL { root.appendingPathComponent("grok.db") }
    var databaseFiles: [URL] { SharedDatabaseLiveness.files(of: database) }

    static let requiredColumns: [String: Set<String>] = [
        "workspaces": ["id", "canonical_path"],
        "sessions": ["id", "workspace_id", "title", "cwd_at_start", "status", "created_at", "updated_at"],
        "messages": ["session_id", "seq", "role", "message_json", "created_at"],
        "tool_calls": ["id", "session_id"],
        "tool_results": ["id", "tool_call_row_id"],
        "usage_events": ["id", "session_id"],
        "compactions": ["id", "session_id"],
    ]

    func probe() -> AdapterStatus {
        guard FileSystem.isDirectory(root) else { return .notInstalled }
        guard FileSystem.exists(database) else { return .readOnly(reason: "~/.grok has no grok.db, so this is not the Grok CLI layout Domovy knows (xAI's Grok Build keeps its data elsewhere). Domovy only measures the folder.") }
        guard let reader = SQLiteReader(url: database) else { return .readOnly(reason: "Domovy could not open ~/.grok/grok.db read-only.") }
        for (table, columns) in Self.requiredColumns.sorted(by: { $0.key < $1.key }) {
            let missing = columns.subtracting(reader.columns(of: table))
            if !missing.isEmpty {
                return .readOnly(reason: "~/.grok/grok.db has a layout Domovy does not know (\(table) lacks \(missing.sorted().joined(separator: ", "))), so it only shows what it can read.")
            }
        }
        let version = reader.rows("PRAGMA user_version").first?.first.flatMap { $0.flatMap { Int($0) } } ?? 0
        guard (1...3).contains(version) else {
            return .readOnly(reason: "~/.grok/grok.db is at schema version \(version); Domovy knows versions 1 to 3, so it only lists what it can read.")
        }
        return .ready
    }

    struct Row: Sendable {
        let id: String
        let title: String?
        let cwd: String?
        let archived: Bool
        let updated: Date?
        let bytes: Int64
    }

    func rows() -> [Row] {
        guard let reader = SQLiteReader(url: database) else { return [] }
        let sql = """
            SELECT s.id, s.title, coalesce(w.canonical_path, s.cwd_at_start), s.status, s.updated_at, s.created_at,
              (SELECT coalesce(sum(length(m.message_json)), 0) FROM messages m WHERE m.session_id = s.id)
            FROM sessions s LEFT JOIN workspaces w ON w.id = s.workspace_id
            """
        return reader.rows(sql).compactMap { cells in
            guard cells.count == 7, let id = cells[0], !id.isEmpty else { return nil }
            return Row(id: id, title: FileSessions.title(cells[1]), cwd: cells[2].flatMap { $0.hasPrefix("/") ? $0 : nil },
                       archived: cells[3] == "archived", updated: FileSessions.date(cells[4]) ?? FileSessions.date(cells[5]),
                       bytes: cells[6].flatMap { Int64($0) } ?? 0)
        }
    }

    /// The session's rows in every table, children first.
    func rowsToDelete(of id: String) -> [DatabaseEdit.Rows] {
        guard let reader = SQLiteReader(url: database) else { return [] }
        func count(_ table: String, _ column: String) -> Int { reader.count(table: table, column: column, equals: id) ?? 0 }
        var rows: [DatabaseEdit.Rows] = []
        for cell in reader.rows("SELECT id FROM tool_calls WHERE session_id = ?1", [id]) {
            guard let callID = cell.first ?? nil, Int(callID) != nil else { continue }
            let n = reader.count(table: "tool_results", column: "tool_call_row_id", equals: callID) ?? 0
            if n > 0 {
                rows.append(.init(table: "tool_results", key: callID, isPrefix: false, count: n, bytes: 0, note: "Tool output", column: "tool_call_row_id", encoding: .integer))
            }
        }
        let bytes = Int64(reader.rows("SELECT coalesce(sum(length(message_json)), 0) FROM messages WHERE session_id = ?1", [id]).first?.first?.flatMap { Int($0) } ?? 0)
        for (table, note) in [("tool_calls", "Tool calls"), ("usage_events", "Token usage"), ("compactions", "Compaction summaries"), ("messages", "Messages")] {
            let n = count(table, "session_id")
            if n > 0 { rows.append(.init(table: table, key: id, isPrefix: false, count: n, bytes: table == "messages" ? bytes : 0, note: note, column: "session_id")) }
        }
        rows.append(.init(table: "sessions", key: id, isPrefix: false, count: count("sessions", "id"), bytes: 0, note: "The session", column: "id"))
        return rows
    }
}

/// Adapter for the community Grok CLI. Lists `grok.db`'s sessions; delete removes the session's
/// rows from it (Grok has no command for that), with Grok quit, after cloning the database into
/// the quarantine and with an integrity check afterwards. There is no archive.
public struct GrokAdapter: AgentAdapter {
    public let kind: AgentKind = .grok
    public let root: URL

    let layout: GrokLayout
    let openHandles: any OpenHandleChecker
    let processes: any RunningProcessLister

    /// `grok` (package.json bin of `grok-dev`), run by Bun.
    public static let processMatcher = ProcessMatcher(appName: "Grok CLI", names: ["grok"], quitAdvice: "Quit Grok CLI to change its sessions.",
                                                      argumentMarkers: ["grok-dev", "grok-cli"])

    public static let acknowledgement = "Undo puts grok.db back only while nothing else has changed in it. Once Grok CLI runs again, undo is no longer possible and the session is gone for good."

    public init(grokHome: URL, openHandles: any OpenHandleChecker = LibprocOpenHandleChecker(), processes: any RunningProcessLister = LibprocProcessLister()) {
        self.root = grokHome.standardizedFileURL
        self.layout = GrokLayout(root: self.root)
        self.openHandles = openHandles
        self.processes = processes
    }

    public init(home: URL) {
        self.init(grokHome: home.appendingPathComponent(".grok", isDirectory: true), openHandles: LibprocOpenHandleChecker.shared)
    }

    public func status() async -> AdapterStatus { layout.probe() }

    public func sessions() async throws -> [Session] {
        guard FileSystem.isDirectory(root) else { throw AdapterError.notInstalled(kind) }
        let live = await liveness()
        return layout.rows().map { row in
            Session(id: row.id, agent: kind, title: row.title, projectPath: row.cwd, lastActive: row.updated ?? .distantPast,
                    sizeBytes: row.bytes, status: live.isLive ? .live : row.archived ? .archived : .idle, expiresAt: nil,
                    transcriptURL: layout.database, isArchived: row.archived)
        }
        .sorted { $0.lastActive > $1.lastActive }
    }

    public func artifacts(of session: Session) async throws -> [Artifact] {
        let row = try locate(session)
        return [Artifact(url: layout.database, kind: .indexEntry, sizeBytes: row.bytes, note: "Messages, tool calls and usage rows in grok.db")]
    }

    public func liveCheck(_ session: Session) async throws -> LiveCheckResult {
        _ = try locate(session)
        return await liveness()
    }

    public func deletePlan(for session: Session, destination: Destination = .trash) async throws -> Plan {
        _ = try locate(session)
        if case .readOnly(let reason) = layout.probe() { throw AdapterError.readOnly(kind, reason: reason) }
        guard SafeID.isSafe(session.id) else { throw AdapterError.unsafeID(kind, id: session.id) }
        let live = SharedDatabaseLiveness.forPlan(await liveness(), what: "grok.db")
        let edit = DatabaseEdit(database: layout.database, files: layout.databaseFiles, rows: layout.rowsToDelete(of: session.id), listRemovals: [])
        let copy = CleanupPlan.bytes(layout.databaseFiles.reduce(Int64(0)) { $0 + FileSystem.size(of: $1) })
        return Plan(agent: kind, sessionID: session.id, action: .delete, destination: destination, moves: [], indexEdits: [], databaseEdits: [edit],
                    remarks: [
                        "Grok CLI has no command to delete a session, so Domovy deletes its rows from grok.db itself, with Grok CLI quit. First it keeps a copy of the whole database (\(copy)) in its quarantine; afterwards it checks the database is intact and puts the copy back if not.",
                        "The space stays inside grok.db for Grok CLI to reuse. wallet.json and your settings are never touched.",
                    ],
                    acknowledgement: Self.acknowledgement, mustNotBeRunning: [Self.processMatcher], liveCheck: live, scope: [root])
    }

    public func archivePlan(for session: Session) async throws -> Plan {
        _ = try locate(session)
        return Plan(agent: kind, sessionID: session.id, action: .archive, destination: nil, moves: [], indexEdits: [],
                    remarks: ["Grok CLI keeps sessions inside grok.db, so there is no file of this session to compress. Domovy leaves the database as it is."],
                    liveCheck: await liveness(), scope: [root])
    }

    /// `message_json` is an AI SDK message: `{role, content}` with content a string or parts
    /// `{type: text, text}` / `{type: tool-call, toolName}`.
    public func transcript(of session: Session, limit: Int, masking findings: [SecretFinding]) async throws -> Transcript {
        _ = try locate(session)
        guard let reader = SQLiteReader(url: layout.database) else { return .empty }
        let masker = TranscriptMask.TextMasker()
        var messages: [TranscriptMessage] = []
        for cell in reader.rows("SELECT seq, role, message_json, created_at FROM messages WHERE session_id = ?1 ORDER BY seq LIMIT \(max(0, limit) * 4 + 1)", [session.id]) where cell.count == 4 {
            let role: TranscriptMessage.Role
            switch cell[1] {
            case "user": role = .user
            case "assistant": role = .assistant
            default: continue
            }
            guard let data = cell[2]?.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            var blocks: [TranscriptMessage.Block] = []
            if let text = FileSessions.text(of: object["content"]) { blocks.append(.text(masker.mask(text))) }
            for case let part as [String: Any] in object["content"] as? [Any] ?? [] where part["type"] as? String == "tool-call" {
                blocks.append(.toolCall((part["toolName"] as? String) ?? "Tool"))
            }
            guard !blocks.isEmpty else { continue }
            if messages.count == limit { return Transcript(messages: messages, isTruncated: true) }
            messages.append(TranscriptMessage(id: "g\(cell[0] ?? "\(messages.count)")", role: role, timestamp: FileSessions.date(cell[3]), blocks: blocks))
        }
        return Transcript(messages: messages, isTruncated: false)
    }

    private func liveness() async -> LiveCheckResult {
        await SharedDatabaseLiveness.check(app: Self.processMatcher, files: layout.databaseFiles, what: "grok.db",
                                           processes: processes, openHandles: openHandles)
    }

    private func locate(_ session: Session) throws -> GrokLayout.Row {
        guard session.agent == kind, session.transcriptURL.standardizedFileURL == layout.database.standardizedFileURL,
              let row = layout.rows().first(where: { $0.id == session.id }) else {
            throw AdapterError.sessionNotFound(session.id)
        }
        return row
    }
}

extension GrokAdapter {
    public func footprint() async throws -> Footprint {
        guard FileSystem.isDirectory(root) else { throw AdapterError.notInstalled(kind) }
        var builder = FootprintBuilder(agent: kind, root: root)
        builder.add("Wallet and settings", ["wallet.json", "user-settings.json"].map { root.appendingPathComponent($0) }, reveal: root, .keep,
                    "Grok CLI's wallet and settings. Domovy never touches them.")
        let count = layout.rows().count
        builder.add("Sessions", layout.databaseFiles, reveal: root, .consequences,
                    "\(count) \(count == 1 ? "session" : "sessions") in grok.db. Delete them one by one in Sessions.", guidance: .manageInSessions)
        builder.add("Other", builder.unclaimedChildren(of: root), reveal: root, .keep, "State Domovy does not manage. Left alone.")
        return builder.build()
    }
}
