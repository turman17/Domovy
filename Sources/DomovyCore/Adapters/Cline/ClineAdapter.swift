import Foundation
import os

/// Cline's storage, read from cline/cline@34c104e6 (docs/research/agent_storage_formats.md, Q9; not
/// verified on a real install). The VS Code extension, the CLI and JetBrains share it. Permalink base:
/// https://github.com/cline/cline/blob/34c104e6fc49781cda4adcd73ffdccd8f029fef9/
///
/// - Data folder `~/.cline/data` (`CLINE_DIR`, `CLINE_DATA_DIR`; sdk/packages/shared/src/storage/paths.ts#L158-L200).
/// - Index `db/sessions.db`, table `sessions(session_id, pid, status, started_at, ended_at, cwd, prompt,
///   metadata_json, messages_path, parent_session_id, is_subagent, updated_at, …)`
///   (paths.ts#L247-L253, sdk/packages/shared/src/db/sqlite-db.ts#L188-L217).
/// - Session files `sessions/<id>/<id>.json`, `<id>.messages.json`, `<id>.compaction.json`, sub-agent
///   messages in the root session's folder (sdk/packages/core/src/services/session-artifacts.ts#L34-L94).
/// - A session is live while its status is `idle`, `running` or `pending` and its pid runs
///   (sdk/packages/core/src/session/services/persistence-service.ts#L430-L512).
/// - `cline history delete --session-id <id>` deletes the rows (with child rows), the files, and the
///   session's checkpoint refs in the project's git repository (apps/cli/src/commands/history-command.ts#L63-L76,
///   persistence-service.ts#L586-L645). It never prompts.
struct ClineLayout: Sendable {
    /// `~/.cline/data`.
    let root: URL

    var database: URL { root.appendingPathComponent("db/sessions.db") }
    var databaseFiles: [URL] { SharedDatabaseLiveness.files(of: database) }
    var sessions: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    /// The layout before the SDK: `state/taskHistory.json` and `tasks/<id>/`, which the CLI no
    /// longer reads (apps/vscode/src/sdk/legacy-state-reader.ts#L42-L74).
    var legacyTasks: URL { root.appendingPathComponent("tasks", isDirectory: true) }

    static let protectedEntries: Set<String> = [
        "secrets.json", "globalState.json", "settings", "db", "connectors", "teams", "workspaces", "state",
    ]

    func isProtected(_ url: URL) -> Bool {
        guard let relative = FileSystem.relativePath(of: url, under: root) else { return false }
        let parts = relative.split(separator: "/").map(String.init)
        guard let first = parts.first else { return true }
        if first == "sessions" { return parts.count < 2 }
        return Self.protectedEntries.contains(first)
    }

    static let requiredColumns: Set<String> = [
        "session_id", "pid", "status", "started_at", "cwd", "prompt", "metadata_json", "messages_path", "parent_session_id", "is_subagent", "updated_at",
    ]

    func unknownLayout() -> String? {
        guard let reader = SQLiteReader(url: database) else { return "Domovy could not open Cline's sessions.db read-only." }
        let missing = Self.requiredColumns.subtracting(reader.columns(of: "sessions"))
        guard missing.isEmpty else {
            return "Cline's sessions.db has a layout Domovy does not know (sessions lacks \(missing.sorted().joined(separator: ", "))), so it only shows what it can read."
        }
        return nil
    }

    struct Row: Sendable {
        let id: String
        let pid: Int32?
        let status: String
        let cwd: String?
        let title: String?
        let started: Date?
        let updated: Date?
        let messagesPath: String?
        let parentID: String?
        let isSubagent: Bool

        var isRunningStatus: Bool { ["idle", "running", "pending"].contains(status) }
    }

    func rows() -> [String: Row] {
        guard let reader = SQLiteReader(url: database) else { return [:] }
        let sql = "SELECT session_id, pid, status, cwd, prompt, metadata_json, started_at, updated_at, messages_path, parent_session_id, is_subagent FROM sessions"
        var rows: [String: Row] = [:]
        for cells in reader.rows(sql) where cells.count == 11 {
            guard let id = cells[0], !id.isEmpty else { continue }
            let metadata = cells[5].flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            rows[id] = Row(id: id, pid: cells[1].flatMap { Int32($0) }, status: cells[2] ?? "",
                           cwd: cells[3].flatMap { $0.hasPrefix("/") ? $0 : nil },
                           title: FileSessions.title(metadata?["title"] as? String) ?? FileSessions.title(cells[4]),
                           started: FileSessions.date(cells[6]), updated: FileSessions.date(cells[7]),
                           messagesPath: cells[8].flatMap { $0.isEmpty ? nil : $0 }, parentID: cells[9].flatMap { $0.isEmpty ? nil : $0 },
                           isSubagent: cells[10] == "1")
        }
        return rows
    }

    func folder(of id: String) -> URL { sessions.appendingPathComponent(id, isDirectory: true) }
}

/// The `cline` executable, when `cline history --help` lists `delete`.
public struct ClineCLI: Sendable, Hashable {
    let executable: URL

    static func probe(_ executable: URL, dataFolder: URL) -> ClineCLI? {
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              let help = ExternalTool.output(executable, ["history", "--help"], environment: ["CLINE_DATA_DIR": dataFolder.path], timeout: 20, mergingErrors: true),
              help.status == 0, help.stdout.contains("delete") else {
            Log.adapter.info("cline history --help does not list delete; Cline stays unchanged")
            return nil
        }
        return ClineCLI(executable: executable)
    }

    public static func choice(home: URL, isCustomHome: Bool) -> ToolChoice {
        ToolChoice.at(home: home, isCustomHome: isCustomHome, name: "cline", override: "DOMOVY_CLINE_CLI")
    }
}

/// Adapter for Cline. Sessions are rows of `sessions.db` with a folder each; Domovy never writes the
/// database. Delete runs `cline history delete` (safety rule 3) with the CLI quit and nothing holding
/// the database open, after keeping a copy of the session's folder and cloning the database, then
/// checks the rows and folder are gone. Archive compresses the session's files in place.
public struct ClineAdapter: AgentAdapter {
    public let kind: AgentKind = .cline
    public let root: URL

    let layout: ClineLayout
    let openHandles: any OpenHandleChecker
    let processes: any RunningProcessLister
    let probe: any ProcessProbe
    let choice: ToolChoice
    private let cached = OSAllocatedUnfairLock<ClineCLI??>(initialState: nil)

    /// `cline` (apps/cli/package.json bin) under node or bun.
    public static let processMatcher = ProcessMatcher(appName: "Cline CLI", names: ["cline"], quitAdvice: "Quit Cline CLI to change its sessions.",
                                                      argumentMarkers: ["@cline/cli"])

    public static let acknowledgement = "Undo puts Cline's session files and its sessions.db back only while nothing else has changed the database. Cline's own delete also removes the session's checkpoint refs from the project's git repository, which undo does not bring back."

    public init(dataFolder: URL, cli: ToolChoice = .automatic, openHandles: any OpenHandleChecker = LibprocOpenHandleChecker(),
                processes: any RunningProcessLister = LibprocProcessLister(), probe: any ProcessProbe = KillProcessProbe()) {
        self.root = dataFolder.standardizedFileURL
        self.layout = ClineLayout(root: self.root)
        self.choice = cli
        self.openHandles = openHandles
        self.processes = processes
        self.probe = probe
    }

    public init(home: URL, cli: ToolChoice = .automatic) {
        self.init(dataFolder: home.appendingPathComponent(".cline/data", isDirectory: true), cli: cli, openHandles: LibprocOpenHandleChecker.shared)
    }

    var commandLineTool: ClineCLI? {
        if let known = cached.withLock({ $0 }) { return known }
        let found = choice.resolve("cline").flatMap { ClineCLI.probe($0, dataFolder: root) }
        cached.withLock { $0 = .some(found) }
        return found
    }

    // MARK: AgentAdapter

    public func status() async -> AdapterStatus {
        guard FileSystem.isDirectory(root) else { return .notInstalled }
        guard FileSystem.exists(layout.database) else {
            if FileSystem.isDirectory(layout.legacyTasks) {
                return .readOnly(reason: "This Cline keeps tasks in the older layout (tasks/ and state/taskHistory.json), which Domovy does not change.")
            }
            return .ready
        }
        if let reason = layout.unknownLayout() { return .readOnly(reason: reason) }
        return .ready
    }

    public func sessions() async throws -> [Session] {
        guard FileSystem.isDirectory(root) else { throw AdapterError.notInstalled(kind) }
        let rows = layout.rows()
        let top = rows.values.filter { !$0.isSubagent && ($0.parentID.map { rows[$0] == nil } ?? true) && SafeID.isSafe($0.id) }
        let database = await databaseLiveness()
        let holders = await openHandleHolders(of: top.map { [layout.folder(of: $0.id)] }, checker: openHandles)
        return zip(top, holders).map { row, holders in
            let folder = layout.folder(of: row.id)
            let messages = folder.appendingPathComponent("\(row.id).messages.json")
            let live = liveness(row, rows: rows, holders: holders, database: database)
            let archived = APFSCompression.isCompressed(messages)
            return Session(id: row.id, agent: kind, title: row.title, projectPath: row.cwd,
                           lastActive: row.updated ?? row.started ?? FileSystem.modificationDate(of: folder) ?? .distantPast,
                           sizeBytes: FileSystem.size(of: folder), status: live.isLive ? .live : archived ? .archived : .idle, expiresAt: nil,
                           transcriptURL: messages, isArchived: archived)
        }
        .sorted { $0.lastActive > $1.lastActive }
    }

    public func artifacts(of session: Session) async throws -> [Artifact] {
        let (row, rows) = try locate(session)
        let children = rows.values.filter { $0.parentID == row.id }
        var artifacts = folders(row, rows: rows).map { Artifact(url: $0, kind: .folder, sizeBytes: FileSystem.size(of: $0), note: "Session folder: messages, manifest, compaction") }
        artifacts.append(Artifact(url: layout.database, kind: .indexEntry, sizeBytes: 0,
                                  note: "\(children.count + 1) \(children.isEmpty ? "row" : "rows") in sessions.db; Cline removes them"))
        return artifacts
    }

    public func liveCheck(_ session: Session) async throws -> LiveCheckResult {
        let (row, rows) = try locate(session)
        let holders = await openHandles.holders(of: [layout.folder(of: row.id)])
        return liveness(row, rows: rows, holders: holders, database: await databaseLiveness())
    }

    public func deletePlan(for session: Session, destination: Destination = .trash) async throws -> Plan {
        let (row, rows) = try locate(session)
        if case .readOnly(let reason) = await status() { throw AdapterError.readOnly(kind, reason: reason) }
        guard SafeID.isSafe(row.id) else { throw AdapterError.unsafeID(kind, id: row.id) }
        // Cline removes the folder of messages_path; Domovy plans only for paths inside the session folder.
        if let path = row.messagesPath, FileSystem.relativePath(of: URL(fileURLWithPath: path), under: layout.folder(of: row.id)) == nil {
            throw AdapterError.readOnly(kind, reason: "This session's messages are outside Cline's sessions folder, so Cline's delete would remove a folder Domovy cannot keep a copy of.")
        }
        let base = try await liveCheck(session)
        let blocking = processes.blockingReasons([Self.processMatcher])
        let live = FileSessions.forPlan(SharedDatabaseLiveness.forPlan(base, what: "Cline's sessions.db"), blocking: blocking, app: "Cline CLI")
        guard let tool = commandLineTool else {
            return Plan(agent: kind, sessionID: session.id, action: .delete, destination: destination, moves: [], indexEdits: [],
                        remarks: ["Cline's own command (`cline history delete`) was not found, so nothing will change. Domovy never edits Cline's database itself."],
                        liveCheck: live, scope: scope)
        }
        let folders = folders(row, rows: rows)
        let command = PlannedCommand(
            executable: tool.executable,
            arguments: ["history", "delete", "--session-id", row.id],
            environment: ["CLINE_DATA_DIR": root.path],
            note: "Runs `cline history delete` for this session and its sub-agents, then checks its rows and files are gone.",
            copiesBeforeRun: folders,
            snapshotsBeforeRun: layout.databaseFiles.filter { FileSystem.exists($0) },
            verifications: [.rowsGone(database: layout.database, table: "sessions", column: "session_id", value: row.id),
                            .rowsGone(database: layout.database, table: "sessions", column: "parent_session_id", value: row.id)]
                + folders.map { .fileGone($0) },
            sizeBytes: folders.reduce(0) { $0 + FileSystem.size(of: $1) })
        var remarks = ["Cline deletes the session itself; Domovy never writes to sessions.db. First Domovy keeps a copy of the session's files and of the database in its quarantine."]
        remarks.append("Cline also removes this session's checkpoint refs (refs/cline/checkpoints/\(row.id)) from the project's git repository. Undo does not bring those back.")
        return Plan(agent: kind, sessionID: session.id, action: .delete, destination: destination, moves: [], indexEdits: [],
                    commands: [command], remarks: remarks, acknowledgement: Self.acknowledgement, mustNotBeRunning: [Self.processMatcher],
                    liveCheck: live, scope: scope)
    }

    public func archivePlan(for session: Session) async throws -> Plan {
        let (row, rows) = try locate(session)
        if case .readOnly(let reason) = await status() { throw AdapterError.readOnly(kind, reason: reason) }
        let artifacts = folders(row, rows: rows).map { Artifact(url: $0, kind: .folder, sizeBytes: 0, note: "Session file") }
        let compressions = try FileSessions.compressions(of: artifacts, isProtected: layout.isProtected)
        return Plan(agent: kind, sessionID: session.id, action: .archive, destination: nil, moves: [], indexEdits: [], compressions: compressions,
                    liveCheck: try await liveCheck(session), scope: scope)
    }

    /// `<id>.messages.json`: `{messages: [{role, content}]}` with content a string or blocks
    /// (`text`, `tool_use`, …; sdk/packages/core/src/services/session-data.ts#L334-L359,
    /// sdk/packages/shared/src/llms/messages.ts#L130-L165). Text is masked before it is shown.
    public func transcript(of session: Session, limit: Int, masking findings: [SecretFinding]) async throws -> Transcript {
        let (row, _) = try locate(session)
        let file = layout.folder(of: row.id).appendingPathComponent("\(row.id).messages.json")
        guard FileSystem.size(of: file) <= 16 * 1024 * 1024, let object = FileSessions.object(file) else { return .empty }
        let masker = TranscriptMask.TextMasker()
        var messages: [TranscriptMessage] = []
        for (index, message) in (object["messages"] as? [[String: Any]] ?? []).enumerated() {
            let role: TranscriptMessage.Role
            switch message["role"] as? String {
            case "user": role = .user
            case "assistant": role = .assistant
            default: continue
            }
            var blocks: [TranscriptMessage.Block] = []
            if let text = FileSessions.text(of: message["content"]) { blocks.append(.text(masker.mask(text))) }
            for case let block as [String: Any] in message["content"] as? [Any] ?? [] where block["type"] as? String == "tool_use" {
                blocks.append(.toolCall((block["name"] as? String) ?? "Tool"))
            }
            guard !blocks.isEmpty else { continue }
            if messages.count == limit { return Transcript(messages: messages, isTruncated: true) }
            messages.append(TranscriptMessage(id: (message["id"] as? String) ?? "c\(index)", role: role, timestamp: FileSessions.epoch(message["ts"]), blocks: blocks))
        }
        return Transcript(messages: messages, isTruncated: false)
    }

    // MARK: Helpers

    /// The session's folder and those of its children, where they exist.
    private func folders(_ row: ClineLayout.Row, rows: [String: ClineLayout.Row]) -> [URL] {
        ([row.id] + rows.values.filter { $0.parentID == row.id }.map(\.id).sorted()).filter(SafeID.isSafe)
            .map { layout.folder(of: $0) }.filter(FileSystem.isDirectory)
    }

    private func databaseLiveness() async -> [String] {
        var reasons: [String] = []
        var seen = Set<Int32>()
        for holder in await openHandles.holders(of: layout.databaseFiles) ?? [] where seen.insert(holder.pid).inserted {
            reasons.append("\(holder.processName) (pid \(holder.pid)) has Cline's sessions.db open, so Domovy cannot tell which session it uses. Quit Cline (and VS Code, if the extension runs) first.")
        }
        return reasons
    }

    /// Cline's own rule: a non-terminal status whose pid still runs. The pid may be VS Code's
    /// extension host, which also counts.
    private func liveness(_ row: ClineLayout.Row, rows: [String: ClineLayout.Row], holders: [OpenHandleHolder]?, database: [String]) -> LiveCheckResult {
        var reasons = database
        for member in [row] + rows.values.filter({ $0.parentID == row.id }) where member.isRunningStatus {
            if let pid = member.pid, probe.isRunning(pid) {
                reasons.append("Cline reports this session as \(member.status) (pid \(pid)). Stop it in Cline first.")
                break
            }
        }
        return FileSessions.liveness(markers: reasons, holders: holders, signals: ["sessions.db status and pid"])
    }

    private func locate(_ session: Session) throws -> (ClineLayout.Row, [String: ClineLayout.Row]) {
        guard session.agent == kind, SafeID.isSafe(session.id),
              session.transcriptURL.standardizedFileURL.deletingLastPathComponent() == layout.folder(of: session.id).standardizedFileURL else {
            throw AdapterError.sessionNotFound(session.id)
        }
        let rows = layout.rows()
        guard let row = rows[session.id] else { throw AdapterError.sessionNotFound(session.id) }
        return (row, rows)
    }
}

extension ClineAdapter {
    public func footprint() async throws -> Footprint {
        guard FileSystem.isDirectory(root) else { throw AdapterError.notInstalled(kind) }
        var builder = FootprintBuilder(agent: kind, root: root)
        builder.add("Settings and sign-in", ClineLayout.protectedEntries.subtracting(["db"]).sorted().map { root.appendingPathComponent($0) }, reveal: root, .keep,
                    "Cline needs these to run. Domovy never removes them.")
        builder.add("Session index", root.appendingPathComponent("db", isDirectory: true), .keep, "Cline's sessions.db and its other databases. Domovy never edits them.")
        let count = layout.rows().values.filter { !$0.isSubagent && $0.parentID == nil }.count
        builder.add("Sessions", layout.sessions, .consequences,
                    "\(count) \(count == 1 ? "session" : "sessions"). Delete them one by one in Sessions; Cline runs the delete.", guidance: .manageInSessions)
        builder.add("Older tasks", layout.legacyTasks, .consequences,
                    "Tasks in the layout of older Cline versions. The VS Code extension still shows them; the CLI does not. Domovy leaves them.")
        builder.add("Logs", root.appendingPathComponent("logs", isDirectory: true), .safe, "Diagnostic logs. Remove them while Cline is quit.")
        builder.add("Other", builder.unclaimedChildren(of: root), reveal: root, .keep, "Caches and state Domovy does not manage yet. Left alone.")
        return builder.build()
    }
}
