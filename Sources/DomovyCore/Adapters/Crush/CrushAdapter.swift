import Foundation
import os

/// Crush's storage, read from charmbracelet/crush@ee51fe87 (docs/research/agent_storage_formats.md,
/// Q9; not verified on a real install). Permalink base:
/// https://github.com/charmbracelet/crush/blob/ee51fe87bb306a945bf9057edf94f5574b192fd2/
///
/// - Each project has its own data folder (`<project>/.crush` by default; internal/config/config.go#L26,
///   internal/config/load.go#L744-L753) with one SQLite database, `crush.db`, in WAL mode
///   (internal/db/connect.go#L20-L29, #L101).
/// - The only global list of those folders is `~/.local/share/crush/projects.json`:
///   `{projects: [{path, data_dir, last_accessed}]}` (internal/projects/projects.go#L17-L41, #L122-L148).
/// - `sessions(id, parent_session_id, title, message_count, …, updated_at, created_at)` (unix seconds);
///   `messages(id, session_id, role, parts, …)` and `files` cascade with their session, child sessions
///   (`title-<id>`, sub-agent tasks) do not (internal/db/migrations/20250424200609_initial.sql#L4-L82,
///   internal/session/session.go#L119-L178).
/// - `crush session delete <id>` (alias `rm`) never prompts and takes `-D <data dir>` and
///   `--cwd <dir>` (internal/cmd/session.go#L71-L78, #L293-L327, internal/cmd/root.go#L58-L66). It
///   also runs Crush's migrations on the database (connect.go#L170-L182).
/// - A Crush TUI leaves no lock (crush.lock is taken only in server mode, internal/db/datadirlock.go#L23-L103).
struct CrushLayout: Sendable {
    /// `~/.local/share/crush`.
    let root: URL

    var projectsFile: URL { root.appendingPathComponent("projects.json") }

    struct Store: Sendable, Hashable {
        /// The project folder (`path`).
        let project: String
        /// The data folder (`data_dir`).
        let folder: URL
        var database: URL { folder.appendingPathComponent("crush.db") }
        var databaseFiles: [URL] { ["", "-wal", "-shm"].map { folder.appendingPathComponent("crush.db" + $0) } }
    }

    /// Projects whose data folder holds a `crush.db`. Paths must be absolute.
    func stores() -> [Store] {
        guard let list = FileSessions.object(projectsFile)?["projects"] as? [[String: Any]] else { return [] }
        var seen = Set<URL>()
        return list.compactMap { entry in
            guard let path = entry["path"] as? String, path.hasPrefix("/"),
                  let dataDir = entry["data_dir"] as? String, dataDir.hasPrefix("/") else { return nil }
            let folder = URL(fileURLWithPath: dataDir, isDirectory: true).standardizedFileURL
            guard !folder.path.contains("/../"), FileSystem.exists(folder.appendingPathComponent("crush.db")), seen.insert(folder).inserted else { return nil }
            return Store(project: path, folder: folder)
        }
    }

    static let requiredColumns: [String: Set<String>] = [
        "sessions": ["id", "parent_session_id", "title", "message_count", "updated_at", "created_at"],
        "messages": ["id", "session_id", "role", "parts", "created_at"],
    ]

    func unknownLayout(_ store: Store) -> String? {
        guard let reader = SQLiteReader(url: store.database) else { return "Domovy could not open \(store.database.path) read-only." }
        for (table, columns) in Self.requiredColumns.sorted(by: { $0.key < $1.key }) {
            let missing = columns.subtracting(reader.columns(of: table))
            if !missing.isEmpty {
                return "A Crush database has a layout Domovy does not know (\(table) lacks \(missing.sorted().joined(separator: ", "))), so it only shows what it can read."
            }
        }
        return nil
    }

    struct Row: Sendable {
        let id: String
        let parentID: String?
        let title: String?
        let messageCount: Int
        let updated: Date?
        let created: Date?
        let bytes: Int64
    }

    static func rows(_ store: Store) -> [String: Row] {
        guard let reader = SQLiteReader(url: store.database) else { return [:] }
        let sql = """
            SELECT s.id, s.parent_session_id, s.title, s.message_count, s.updated_at, s.created_at,
              (SELECT coalesce(sum(length(m.parts)), 0) FROM messages m WHERE m.session_id = s.id)
            FROM sessions s
            """
        var rows: [String: Row] = [:]
        for cells in reader.rows(sql) where cells.count == 7 {
            guard let id = cells[0], !id.isEmpty else { continue }
            rows[id] = Row(id: id, parentID: cells[1].flatMap { $0.isEmpty ? nil : $0 }, title: FileSessions.title(cells[2]),
                           messageCount: cells[3].flatMap { Int($0) } ?? 0, updated: FileSessions.epoch(cells[4]), created: FileSessions.epoch(cells[5]),
                           bytes: cells[6].flatMap { Int64($0) } ?? 0)
        }
        return rows
    }

    /// Every session below `id`, deepest first, so children go before their parents.
    static func descendants(of id: String, in rows: [String: Row]) -> [Row] {
        rows.values.filter { $0.parentID == id }.sorted { $0.id < $1.id }.flatMap { descendants(of: $0.id, in: rows) + [$0] }
    }
}

/// The `crush` executable, when `crush session --help` lists `delete`.
public struct CrushCLI: Sendable, Hashable {
    let executable: URL

    static func probe(_ executable: URL) -> CrushCLI? {
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              let help = ExternalTool.output(executable, ["session", "--help"], timeout: 20, mergingErrors: true),
              help.status == 0, help.stdout.contains("delete") else {
            Log.adapter.info("crush session --help does not list delete; Crush stays unchanged")
            return nil
        }
        return CrushCLI(executable: executable)
    }

    public static func choice(home: URL, isCustomHome: Bool) -> ToolChoice {
        ToolChoice.at(home: home, isCustomHome: isCustomHome, name: "crush", override: "DOMOVY_CRUSH_CLI")
    }
}

/// Adapter for Crush. Sessions are rows of each project's `crush.db`, which Domovy only reads.
/// Delete runs Crush's own `crush session delete` for each child session and then the session
/// (safety rule 3), with Crush quit, after cloning that database into the quarantine, and checks
/// the rows are gone. Without the CLI nothing changes. There is no archive.
public struct CrushAdapter: AgentAdapter {
    public let kind: AgentKind = .crush
    public let root: URL

    let layout: CrushLayout
    let openHandles: any OpenHandleChecker
    let processes: any RunningProcessLister
    let choice: ToolChoice
    private let cached = OSAllocatedUnfairLock<CrushCLI??>(initialState: nil)

    public static let acknowledgement = "Undo puts this project's Crush database back only while nothing else has changed in it. Once Crush runs there again, undo is no longer possible and the session is gone for good."

    public init(dataFolder: URL, cli: ToolChoice = .automatic, openHandles: any OpenHandleChecker = LibprocOpenHandleChecker(),
                processes: any RunningProcessLister = LibprocProcessLister()) {
        self.root = dataFolder.standardizedFileURL
        self.layout = CrushLayout(root: self.root)
        self.choice = cli
        self.openHandles = openHandles
        self.processes = processes
    }

    public init(home: URL, cli: ToolChoice = .automatic) {
        self.init(dataFolder: home.appendingPathComponent(".local/share/crush", isDirectory: true), cli: cli, openHandles: LibprocOpenHandleChecker.shared)
    }

    /// The data folders of every listed project, plus Crush's own folder.
    public var scope: [URL] { [root] + layout.stores().map(\.folder) }

    func matcher(_ store: CrushLayout.Store) -> ProcessMatcher {
        ProcessMatcher(appName: "Crush", names: ["crush"], scope: store.folder, quitAdvice: "Quit Crush in \(URL(fileURLWithPath: store.project).lastPathComponent) to change its sessions.")
    }

    var commandLineTool: CrushCLI? {
        if let known = cached.withLock({ $0 }) { return known }
        let found = choice.resolve("crush").flatMap(CrushCLI.probe)
        cached.withLock { $0 = .some(found) }
        return found
    }

    // MARK: AgentAdapter

    public func status() async -> AdapterStatus {
        guard FileSystem.exists(layout.projectsFile) else { return .notInstalled }
        guard FileSessions.object(layout.projectsFile)?["projects"] is [Any] else {
            return .readOnly(reason: "Crush's projects.json has a shape Domovy does not know (a projects list is expected).")
        }
        for store in layout.stores() {
            if let reason = layout.unknownLayout(store) { return .readOnly(reason: reason) }
        }
        return .ready
    }

    public func sessions() async throws -> [Session] {
        guard FileSystem.exists(layout.projectsFile) else { throw AdapterError.notInstalled(kind) }
        var result: [Session] = []
        for store in layout.stores() {
            let rows = CrushLayout.rows(store)
            let live = await liveness(store)
            for row in rows.values where row.parentID.map({ rows[$0] == nil }) ?? true {
                let family = CrushLayout.descendants(of: row.id, in: rows) + [row]
                result.append(Session(id: row.id, agent: kind, title: row.title, projectPath: store.project,
                                      lastActive: family.compactMap { $0.updated ?? $0.created }.max() ?? .distantPast,
                                      sizeBytes: family.reduce(0) { $0 + $1.bytes }, status: live.isLive ? .live : .idle, expiresAt: nil,
                                      transcriptURL: store.database))
            }
        }
        return result.sorted { $0.lastActive > $1.lastActive }
    }

    public func artifacts(of session: Session) async throws -> [Artifact] {
        let (store, row, rows) = try locate(session)
        let family = CrushLayout.descendants(of: row.id, in: rows) + [row]
        let messages = family.reduce(0) { $0 + $1.messageCount }
        var artifacts = [Artifact(url: store.database, kind: .indexEntry, sizeBytes: family.reduce(0) { $0 + $1.bytes },
                                  note: "\(messages) \(messages == 1 ? "message" : "messages") in crush.db; Crush removes them")]
        if family.count > 1 {
            let n = family.count - 1
            artifacts.append(Artifact(url: store.database, kind: .indexEntry, sizeBytes: 0, note: "\(n) child \(n == 1 ? "session" : "sessions") (title, sub-agents) in crush.db"))
        }
        return artifacts
    }

    public func liveCheck(_ session: Session) async throws -> LiveCheckResult {
        await liveness(try locate(session).0)
    }

    public func deletePlan(for session: Session, destination: Destination = .trash) async throws -> Plan {
        let (store, row, rows) = try locate(session)
        if case .readOnly(let reason) = await status() { throw AdapterError.readOnly(kind, reason: reason) }
        let family = CrushLayout.descendants(of: row.id, in: rows) + [row]
        if let unsafe = family.first(where: { !SafeID.isSafe($0.id) }) { throw AdapterError.unsafeID(kind, id: unsafe.id) }
        let base = await liveness(store)
        let blocking = processes.blockingReasons([matcher(store)])
        let live = FileSessions.forPlan(SharedDatabaseLiveness.forPlan(base, what: "this project's crush.db"), blocking: blocking, app: "Crush")
        guard let tool = commandLineTool else {
            return Plan(agent: kind, sessionID: session.id, action: .delete, destination: destination, moves: [], indexEdits: [],
                        remarks: ["Crush's own command (`crush session delete`) was not found, so nothing will change. Domovy never edits Crush's database itself."],
                        liveCheck: live, scope: scope)
        }
        let commands = family.map { member in
            PlannedCommand(
                executable: tool.executable,
                arguments: ["session", "delete", member.id, "--data-dir", store.folder.path, "--cwd", store.project],
                workingDirectory: FileSystem.isDirectory(URL(fileURLWithPath: store.project)) ? URL(fileURLWithPath: store.project) : nil,
                note: member.id == row.id
                    ? "Runs `crush session delete` for this session, then checks its rows are gone."
                    : "Runs `crush session delete` for a child session first; Crush does not delete those itself.",
                snapshotsBeforeRun: store.databaseFiles,
                verifications: [("sessions", "id"), ("messages", "session_id"), ("files", "session_id")].map {
                    .rowsGone(database: store.database, table: $0.0, column: $0.1, value: member.id)
                },
                sizeBytes: member.bytes)
        }
        let copy = CleanupPlan.bytes(store.databaseFiles.reduce(Int64(0)) { $0 + FileSystem.size(of: $1) })
        var remarks = ["Crush deletes the session from this project's crush.db itself; Domovy never writes to that database. First Domovy keeps a copy of it (\(copy)) in its quarantine."]
        if family.count > 1 {
            let n = family.count - 1
            remarks.append("Also deletes its \(n) child \(n == 1 ? "session" : "sessions") (title and sub-agent runs), which Crush's delete leaves behind.")
        }
        return Plan(agent: kind, sessionID: session.id, action: .delete, destination: destination, moves: [], indexEdits: [],
                    commands: commands, remarks: remarks, acknowledgement: Self.acknowledgement, mustNotBeRunning: [matcher(store)],
                    liveCheck: live, scope: scope)
    }

    public func archivePlan(for session: Session) async throws -> Plan {
        let (store, _, _) = try locate(session)
        return Plan(agent: kind, sessionID: session.id, action: .archive, destination: nil, moves: [], indexEdits: [],
                    remarks: ["Crush keeps sessions inside each project's crush.db, so there is no file of this session to compress. Domovy leaves the database as it is."],
                    liveCheck: await liveness(store), scope: scope)
    }

    /// `messages.parts` is `[{type, data}]`: `text` → `data.text`, `tool_call` → `data.name`
    /// (internal/message/message.go#L626-L660, content.go#L81-L83).
    public func transcript(of session: Session, limit: Int, masking findings: [SecretFinding]) async throws -> Transcript {
        let (store, row, _) = try locate(session)
        guard let reader = SQLiteReader(url: store.database) else { return .empty }
        let masker = TranscriptMask.TextMasker()
        let cells = reader.rows("SELECT id, role, parts, created_at FROM messages WHERE session_id = ?1 ORDER BY created_at, id LIMIT \(max(0, limit) + 1)", [row.id])
        var messages: [TranscriptMessage] = []
        for cell in cells where cell.count == 4 {
            let role: TranscriptMessage.Role
            switch cell[1] {
            case "user": role = .user
            case "assistant": role = .assistant
            default: continue
            }
            guard let data = cell[2]?.data(using: .utf8), let parts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            var blocks: [TranscriptMessage.Block] = []
            for part in parts {
                let body = part["data"] as? [String: Any] ?? [:]
                switch part["type"] as? String {
                case "text":
                    if body["hidden"] as? Bool != true, let text = (body["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                        blocks.append(.text(masker.mask(text)))
                    }
                case "tool_call": blocks.append(.toolCall((body["name"] as? String) ?? "Tool"))
                default: break
                }
            }
            guard !blocks.isEmpty else { continue }
            if messages.count == limit { return Transcript(messages: messages, isTruncated: true) }
            messages.append(TranscriptMessage(id: cell[0] ?? "c\(messages.count)", role: role, timestamp: FileSessions.epoch(cell[3]), blocks: blocks))
        }
        return Transcript(messages: messages, isTruncated: false)
    }

    // MARK: Helpers

    /// Crush keeps one database per project; while anything holds it open, every session of that
    /// project counts as live.
    private func liveness(_ store: CrushLayout.Store) async -> LiveCheckResult {
        let holders = await openHandles.holders(of: store.databaseFiles, includingMapped: true)
        var reasons: [String] = []
        var seen = Set<Int32>()
        for holder in holders ?? [] where seen.insert(holder.pid).inserted {
            reasons.append("\(holder.processName) (pid \(holder.pid)) has this project's crush.db open, so Domovy cannot tell which session it uses. Quit Crush there first.")
        }
        return LiveCheckResult(isLive: !reasons.isEmpty, reasons: reasons, checkedSignals: ["open file handles"],
                               openHandles: holders == nil ? .unavailable : reasons.isEmpty ? .clear : .open)
    }

    private func locate(_ session: Session) throws -> (CrushLayout.Store, CrushLayout.Row, [String: CrushLayout.Row]) {
        guard session.agent == kind,
              let store = layout.stores().first(where: { $0.database.standardizedFileURL == session.transcriptURL.standardizedFileURL }) else {
            throw AdapterError.sessionNotFound(session.id)
        }
        let rows = CrushLayout.rows(store)
        guard let row = rows[session.id] else { throw AdapterError.sessionNotFound(session.id) }
        return (store, row, rows)
    }
}

extension CrushAdapter {
    public func footprint() async throws -> Footprint {
        guard FileSystem.exists(layout.projectsFile) else { throw AdapterError.notInstalled(kind) }
        var builder = FootprintBuilder(agent: kind, root: root)
        builder.add("Sign-in and project list", ["crush.json", "projects.json", "projects.json.lock", "locks"].map { root.appendingPathComponent($0) },
                    reveal: root, .keep, "Crush's state, provider sign-ins and its list of projects. Domovy never removes them.")
        for store in layout.stores() {
            let name = URL(fileURLWithPath: store.project).lastPathComponent
            let count = CrushLayout.rows(store).values.filter { $0.parentID == nil }.count
            builder.add("Sessions (\(name))", store.databaseFiles.filter { FileSystem.exists($0) }, reveal: store.folder, .consequences,
                        "\(count) \(count == 1 ? "session" : "sessions") in this project's crush.db. Delete them one by one in Sessions; Crush runs the delete.",
                        guidance: .manageInSessions)
            builder.add("Logs (\(name))", store.folder.appendingPathComponent("logs", isDirectory: true), .safe,
                        "Crush's log for this project. It writes a new one; remove it while Crush is quit.")
        }
        builder.add("Other", builder.unclaimedChildren(of: root), reveal: root, .keep, "Caches and state Domovy does not manage yet. Left alone.")
        return builder.build()
    }
}
