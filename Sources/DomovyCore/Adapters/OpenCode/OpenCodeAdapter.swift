import Foundation

/// Adapter for OpenCode (`~/.local/share/opencode`). Sessions are rows of `opencode.db`, which
/// Domovy only reads. Delete runs OpenCode's own `opencode session delete` (safety rule 3) with
/// OpenCode quit, after cloning the whole database into the quarantine, and checks the rows are
/// gone. Undo puts the clone back only while nothing else has written to the database. There is
/// no archive: no file belongs to one session alone.
///
/// The same adapter serves Kilo Code (`OpenCodeFlavor.kilo`), an OpenCode fork with the same
/// tables in `~/.local/share/kilo/kilo.db` and the same `kilo session delete <id>`, which also
/// deletes the session's children (Kilo-Org/kilocode@bfdec549,
/// packages/opencode/src/cli/cmd/session.ts#L54-L71, src/session/session.ts#L723-L726).
public struct OpenCodeAdapter: AgentAdapter {
    public let kind: AgentKind
    /// `~/.local/share/opencode`.
    public let root: URL
    public let flavor: OpenCodeFlavor

    let layout: OpenCodeLayout
    let openHandles: any OpenHandleChecker
    let processes: any RunningProcessLister
    let cli: OpenCodeCLIResolver

    /// `opencode` is the installed binary's name (verified, 1.18.30); the npm package running
    /// under node (`opencode-ai`) is assumed. Blocks only while it uses this data folder.
    public var processMatcher: ProcessMatcher {
        Self.processMatcher(dataFolder: root, flavor: flavor)
    }

    public static func processMatcher(dataFolder: URL? = nil, flavor: OpenCodeFlavor = .openCode) -> ProcessMatcher {
        ProcessMatcher(appName: flavor.appName, names: [flavor.executable], scope: dataFolder,
                       quitAdvice: "Quit \(flavor.appName) to change its sessions.", argumentMarkers: [flavor.npmMarker])
    }

    public static let acknowledgement = acknowledgement(.openCode)

    public static func acknowledgement(_ flavor: OpenCodeFlavor) -> String {
        "Undo puts \(flavor.appName)'s database back only while nothing else has changed in it. Once \(flavor.appName) runs again, undo is no longer possible and the session is gone for good."
    }

    /// - Parameters:
    ///   - dataFolder: `~/.local/share/opencode`. Tests pass a copy of a fixture.
    ///   - configFolder: `~/.config/opencode`, measured as settings only.
    ///   - cli: which `opencode` delete runs; tests pass a stub, `.none` to see the plan without it.
    public init(
        dataFolder: URL,
        configFolder: URL,
        cli: ToolChoice = .automatic,
        flavor: OpenCodeFlavor = .openCode,
        openHandles: any OpenHandleChecker = LibprocOpenHandleChecker(),
        processes: any RunningProcessLister = LibprocProcessLister()
    ) {
        self.kind = flavor.kind
        self.flavor = flavor
        self.root = dataFolder.standardizedFileURL
        self.layout = OpenCodeLayout(root: self.root, config: configFolder.standardizedFileURL, flavor: flavor)
        self.openHandles = openHandles
        self.processes = processes
        self.cli = OpenCodeCLIResolver(choice: cli, dataFolder: self.root, flavor: flavor)
    }

    /// Convenience for a home directory: `<home>/.local/share/<folder>` and `<home>/.config/<folder>`.
    public init(home: URL, cli: ToolChoice = .automatic, flavor: OpenCodeFlavor = .openCode) {
        self.init(dataFolder: home.appendingPathComponent(".local/share/\(flavor.folder)", isDirectory: true),
                  configFolder: home.appendingPathComponent(".config/\(flavor.folder)", isDirectory: true), cli: cli, flavor: flavor,
                  openHandles: LibprocOpenHandleChecker.shared)
    }

    /// The `opencode` executable delete plans run, or `nil` when there is none.
    public var commandLineTool: OpenCodeCLI? { cli.resolve() }

    // MARK: AgentAdapter

    public func status() async -> AdapterStatus {
        layout.probe()
    }

    public func sessions() async throws -> [Session] {
        if case .notInstalled = layout.probe() { throw AdapterError.notInstalled(kind) }
        let index = OpenCodeIndex.load(layout)
        let live = await storeLiveness()
        return index.topLevel.map { makeSession($0, index: index, live: live) }.sorted { $0.lastActive > $1.lastActive }
    }

    public func artifacts(of session: Session) async throws -> [Artifact] {
        let (row, index) = try locate(session)
        return collectArtifacts(row, index: index)
    }

    public func liveCheck(_ session: Session) async throws -> LiveCheckResult {
        _ = try locate(session)
        return await storeLiveness()
    }

    public func deletePlan(for session: Session, destination: Destination = .trash) async throws -> Plan {
        let (row, index) = try locate(session)
        try requireWritable()
        let family = index.descendants(of: row.id) + [row]
        // Ids come from OpenCode's database and end up in a path and on `opencode`'s command line.
        if let unsafe = family.first(where: { !SafeID.isSafe($0.id) }) { throw AdapterError.unsafeID(kind, id: unsafe.id) }
        let live = await planCheck()
        let app = flavor.appName, exe = flavor.executable, db = flavor.databaseName
        guard let tool = cli.resolve() else {
            return Plan(agent: kind, sessionID: session.id, action: .delete, destination: destination, moves: [], indexEdits: [],
                        remarks: ["\(app)'s own command (`\(exe) session delete`) was not found, so nothing will change. Domovy never edits \(app)'s database itself."],
                        liveCheck: live, scope: self.scope)
        }
        let reader = SQLiteReader(url: layout.database)
        let commands = family.map { member in
            PlannedCommand(
                executable: tool.executable,
                arguments: ["session", "delete", member.id, "--pure"],
                environment: flavor.environment(dataFolder: root),
                note: member.id == row.id
                    ? "Runs `\(exe) session delete` for this session, then checks its rows are gone."
                    : "Runs `\(exe) session delete` for a subagent session of it first.",
                snapshotsBeforeRun: layout.databaseFiles,
                verifications: verifications(for: member.id, reader: reader),
                sizeBytes: member.contentBytes + member.eventBytes
            )
        }
        let diffs = family.map { layout.sessionDiff($0.id) }.filter { FileSystem.exists($0) && !layout.isProtected($0) }
        let moves = diffs.map { FileMove(source: $0, kind: .file, sizeBytes: FileSystem.size(of: $0), note: "Session diff") }
        let copyBytes = CleanupPlan.bytes(layout.databaseFiles.reduce(Int64(0)) { $0 + FileSystem.size(of: $1) })
        var remarks = ["\(app) deletes the session from \(db) itself; Domovy never writes to that database. First Domovy keeps a copy of the whole database (\(copyBytes)) in its quarantine."]
        if family.count > 1 {
            let n = family.count - 1
            remarks.append("Also deletes its \(n) subagent \(n == 1 ? "session" : "sessions").")
        }
        remarks.append("The space stays inside \(db) for \(app) to reuse; the file itself does not shrink.")
        return Plan(agent: kind, sessionID: session.id, action: .delete, destination: destination, moves: moves, indexEdits: [],
                    commands: commands, remarks: remarks, acknowledgement: Self.acknowledgement(flavor),
                    mustNotBeRunning: [processMatcher], liveCheck: live, scope: self.scope)
    }

    /// Nothing to compress: a session is rows inside the shared database.
    public func archivePlan(for session: Session) async throws -> Plan {
        _ = try locate(session)
        return Plan(agent: kind, sessionID: session.id, action: .archive, destination: nil, moves: [], indexEdits: [],
                    remarks: ["\(flavor.appName) keeps sessions inside \(flavor.databaseName), so there is no file of this session to compress. Domovy leaves the database as it is."],
                    liveCheck: await storeLiveness(), scope: self.scope)
    }

    public func transcript(of session: Session, limit: Int, masking findings: [SecretFinding]) async throws -> Transcript {
        let (row, _) = try locate(session)
        return OpenCodeIndex.transcript(layout, id: row.id, limit: limit)
    }

    // MARK: Sessions

    private func makeSession(_ row: OpenCodeIndex.Row, index: OpenCodeIndex, live: LiveCheckResult) -> Session {
        let family = index.descendants(of: row.id) + [row]
        let size = family.reduce(Int64(0)) { $0 + $1.contentBytes + $1.eventBytes + FileSystem.size(of: layout.sessionDiff($1.id)) }
        let lastActive = family.compactMap { $0.updated ?? $0.created }.max() ?? .distantPast
        return Session(
            id: row.id,
            agent: kind,
            title: row.title,
            projectPath: row.directory,
            lastActive: lastActive,
            sizeBytes: size,
            status: live.isLive ? .live : row.isArchived ? .archived : .idle,
            expiresAt: nil,
            transcriptURL: layout.database,
            isArchived: row.isArchived
        )
    }

    // MARK: Artifacts

    /// Rows in the database (shown as index entries; Domovy never edits them) and the session's
    /// diff file of older versions.
    private func collectArtifacts(_ row: OpenCodeIndex.Row, index: OpenCodeIndex) -> [Artifact] {
        let family = index.descendants(of: row.id) + [row]
        var artifacts: [Artifact] = []
        for member in family {
            let diff = layout.sessionDiff(member.id)
            if FileSystem.exists(diff), !layout.isProtected(diff) {
                artifacts.append(Artifact(url: diff, kind: .file, sizeBytes: FileSystem.size(of: diff), note: "Session diff"))
            }
        }
        let messages = family.reduce(0) { $0 + $1.messageCount }
        let content = family.reduce(Int64(0)) { $0 + $1.contentBytes }
        let events = family.reduce(Int64(0)) { $0 + $1.eventBytes }
        artifacts.append(Artifact(url: layout.database, kind: .indexEntry, sizeBytes: content,
                                  note: "\(messages) \(messages == 1 ? "message" : "messages") in \(flavor.databaseName); \(flavor.appName) removes them"))
        if events > 0 {
            artifacts.append(Artifact(url: layout.database, kind: .indexEntry, sizeBytes: events, note: "Event log rows in \(flavor.databaseName)"))
        }
        if family.count > 1 {
            artifacts.append(Artifact(url: layout.database, kind: .indexEntry, sizeBytes: 0,
                                      note: "\(family.count - 1) subagent \(family.count == 2 ? "session" : "sessions") in \(flavor.databaseName)"))
        }
        return artifacts
    }

    /// After `opencode session delete`: no row of the session is left in the tables it lives in.
    private func verifications(for id: String, reader: SQLiteReader?) -> [Verification] {
        let checks = [("session", "id"), ("message", "session_id"), ("part", "session_id"), ("event", "aggregate_id")]
        return checks.compactMap { table, column in
            guard reader?.columns(of: table).contains(column) == true else { return nil }
            return .rowsGone(database: layout.database, table: table, column: column, value: id)
        }
    }

    // MARK: Liveness

    /// OpenCode keeps one database for every session, so when a process has it open Domovy
    /// cannot tell which session is in use: all of them count as live.
    private func storeLiveness() async -> LiveCheckResult {
        var reasons: [String] = []
        let status: LiveCheckResult.OpenHandleStatus
        if let holders = await openHandles.holders(of: layout.databaseFiles) {
            status = holders.isEmpty ? .clear : .open
            var seen = Set<Int32>()
            for holder in holders where seen.insert(holder.pid).inserted {
                reasons.append("\(holder.processName) (pid \(holder.pid)) has \(flavor.appName)'s database open, so Domovy cannot tell which session it uses. Quit \(flavor.appName) first.")
            }
        } else {
            status = .unavailable
        }
        return LiveCheckResult(isLive: !reasons.isEmpty, reasons: reasons, checkedSignals: ["open file handles"], openHandles: status)
    }

    private func planCheck() async -> LiveCheckResult {
        let base = await storeLiveness()
        let blocking = processes.blockingReasons([processMatcher])
        return LiveCheckResult(isLive: base.isLive || !blocking.isEmpty, reasons: base.reasons + blocking,
                               checkedSignals: base.checkedSignals + ["\(flavor.appName) processes"], openHandles: base.openHandles)
    }

    // MARK: Guards

    private func locate(_ session: Session) throws -> (OpenCodeIndex.Row, OpenCodeIndex) {
        guard session.agent == kind, session.transcriptURL.standardizedFileURL == layout.database.standardizedFileURL else {
            throw AdapterError.sessionNotFound(session.id)
        }
        let index = OpenCodeIndex.load(layout)
        guard let row = index.rows[session.id] else { throw AdapterError.sessionNotFound(session.id) }
        return (row, index)
    }

    private func requireWritable() throws {
        switch layout.probe() {
        case .readOnly(let reason): throw AdapterError.readOnly(kind, reason: reason)
        case .notInstalled: throw AdapterError.notInstalled(kind)
        case .ready: break
        }
    }
}
