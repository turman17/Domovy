import Foundation

/// Adapter for GitHub Copilot CLI (`~/.copilot`). One session is one folder,
/// `session-state/<id>/`. Delete moves that folder to the Trash or the quarantine; undo puts it
/// back. Domovy never runs Copilot's `/chronicle reindex`, which would clean the search index but
/// also syncs sessions to the user's GitHub account, and never writes `session-store.db`: rows
/// that still name the session are reported, read only. Archive compresses the files in place.
public struct CopilotAdapter: AgentAdapter {
    public let kind: AgentKind = .copilot
    public let root: URL

    let layout: CopilotLayout
    let openHandles: any OpenHandleChecker
    let processes: any RunningProcessLister
    let probe: any ProcessProbe

    /// `copilot` as a native binary or `node …/@github/copilot/…` (both assumed). The exact,
    /// case-sensitive name keeps other GitHub Copilot apps out.
    public static let processMatcher = ProcessMatcher(
        appName: "Copilot CLI", names: [], exactNames: ["copilot"],
        quitAdvice: "Quit Copilot CLI to change its sessions.", argumentMarkers: ["@github/copilot"]
    )

    public static let reindexWarning = "Copilot CLI's own fix, `/chronicle reindex`, also syncs your sessions to your GitHub account, so Domovy never runs it. Sessions already synced stay in your account."

    /// - Parameters:
    ///   - copilotHome: the `.copilot` folder. Tests pass a copy of a fixture.
    ///   - probe: whether the pid in a session's `inuse.<pid>.lock` still runs.
    public init(
        copilotHome: URL,
        openHandles: any OpenHandleChecker = LibprocOpenHandleChecker(),
        processes: any RunningProcessLister = LibprocProcessLister(),
        probe: any ProcessProbe = KillProcessProbe()
    ) {
        self.root = copilotHome.standardizedFileURL
        self.layout = CopilotLayout(root: self.root)
        self.openHandles = openHandles
        self.processes = processes
        self.probe = probe
    }

    /// Convenience for a home directory: `<home>/.copilot`.
    public init(home: URL) {
        self.init(copilotHome: home.appendingPathComponent(".copilot", isDirectory: true))
    }

    // MARK: AgentAdapter

    public func status() async -> AdapterStatus {
        layout.probe()
    }

    public func sessions() async throws -> [Session] {
        if case .notInstalled = layout.probe() { throw AdapterError.notInstalled(kind) }
        var result: [Session] = []
        for folder in layout.sessionFolders() {
            result.append(await makeSession(folder))
        }
        return result.sorted { $0.lastActive > $1.lastActive }
    }

    public func artifacts(of session: Session) async throws -> [Artifact] {
        let folder = try locate(session)
        var artifacts = [Artifact(url: folder, kind: .folder, sizeBytes: FileSystem.size(of: folder), note: "Session folder: events, plans, checkpoints")]
        if let rows = indexRows(of: session.id), rows > 0 {
            artifacts.append(Artifact(url: layout.sessionStore, kind: .indexEntry, sizeBytes: 0,
                                      note: "\(rows) \(rows == 1 ? "row" : "rows") in session-store.db (search index); Domovy does not edit it"))
        }
        return artifacts
    }

    public func liveCheck(_ session: Session) async throws -> LiveCheckResult {
        await liveness(try locate(session))
    }

    public func deletePlan(for session: Session, destination: Destination = .trash) async throws -> Plan {
        let folder = try locate(session)
        try requireWritable()
        if layout.isProtected(folder) { throw AdapterError.protectedPathInPlan(folder) }
        var remarks: [String] = []
        if let rows = indexRows(of: session.id), rows > 0 {
            remarks.append("\(rows) \(rows == 1 ? "row" : "rows") in session-store.db still name this session. Domovy never edits that database, so Copilot's search and /chronicle may still list it.")
        }
        remarks.append(Self.reindexWarning)
        let move = FileMove(source: folder, kind: .folder, sizeBytes: FileSystem.size(of: folder), note: "Session folder: events, plans, checkpoints")
        return Plan(agent: kind, sessionID: session.id, action: .delete, destination: destination, moves: [move], indexEdits: [],
                    remarks: remarks, mustNotBeRunning: [Self.processMatcher], liveCheck: await planCheck(folder), scope: self.scope)
    }

    /// Compresses the session's files in place; Copilot CLI reads them unchanged.
    public func archivePlan(for session: Session) async throws -> Plan {
        let folder = try locate(session)
        try requireWritable()
        var compressions: [FileCompression] = []
        for file in APFSCompression.regularFiles(at: folder) {
            if layout.isProtected(file) { throw AdapterError.protectedPathInPlan(file) }
            guard !file.lastPathComponent.hasSuffix(".lock"), !APFSCompression.isCompressed(file),
                  FileSystem.size(of: file) > APFSCompression.minimumUsefulSize else { continue }
            compressions.append(FileCompression(
                file: file,
                sizeBytes: APFSCompression.allocatedBytes(of: file),
                estimatedBytes: APFSCompression.estimatedCompressedBytes(of: file),
                modificationTime: FileSystem.modificationTime(of: file),
                note: file.lastPathComponent == "events.jsonl" ? "Events" : "Session file"
            ))
        }
        return Plan(agent: kind, sessionID: session.id, action: .archive, destination: nil, moves: [], indexEdits: [],
                    compressions: compressions, liveCheck: await liveness(folder), scope: self.scope)
    }

    public func transcript(of session: Session, limit: Int, masking findings: [SecretFinding]) async throws -> Transcript {
        let folder = try locate(session)
        return try CopilotEvents.readTranscript(of: folder.appendingPathComponent("events.jsonl"), maxMessages: limit, masking: findings)
    }

    // MARK: Sessions

    private func makeSession(_ folder: URL) async -> Session {
        let events = folder.appendingPathComponent("events.jsonl")
        let header = CopilotEvents.readHeader(of: folder)
        let live = await liveness(folder)
        let archived = APFSCompression.isCompressed(events)
        return Session(
            id: folder.lastPathComponent,
            agent: kind,
            title: header.title,
            projectPath: header.cwd,
            lastActive: FileSystem.modificationDate(of: events) ?? .distantPast,
            sizeBytes: FileSystem.size(of: folder),
            status: live.isLive ? .live : archived ? .archived : .idle,
            expiresAt: nil,
            transcriptURL: events,
            isArchived: archived
        )
    }

    /// Rows of `session-store.db` whose `session_id`, `sessionId` or `id` is this session's id,
    /// across its tables (its schema is not verified). `nil` when there is no index to read.
    func indexRows(of id: String) -> Int? {
        guard let reader = SQLiteReader(url: layout.sessionStore) else { return nil }
        var total = 0
        for table in reader.tables().sorted() where !table.hasPrefix("sqlite_") {
            for column in reader.columns(of: table).intersection(["session_id", "sessionId", "id"]) {
                total += reader.count(table: table, column: column, equals: id) ?? 0
            }
        }
        return total
    }

    // MARK: Liveness

    /// Live when a process holds a file of the session open, or an `inuse.<pid>.lock` in its
    /// folder names a running process (assumed marker).
    private func liveness(_ folder: URL) async -> LiveCheckResult {
        var reasons: [String] = []
        for lock in FileSystem.children(of: folder) where lock.lastPathComponent.hasSuffix(".lock") {
            let digits = lock.lastPathComponent.split(whereSeparator: { !$0.isNumber }).first.flatMap { Int32($0) }
            if let pid = digits, probe.isRunning(pid) {
                reasons.append("Copilot CLI has this session open (pid \(pid)). Close it there first.")
            }
        }
        let status: LiveCheckResult.OpenHandleStatus
        if let holders = await openHandles.holders(of: [folder]) {
            status = holders.isEmpty ? .clear : .open
            var seen = Set<Int32>()
            for holder in holders where seen.insert(holder.pid).inserted {
                reasons.append("\(holder.processName) (pid \(holder.pid)) has a file of this session open.")
            }
        } else {
            status = .unavailable
        }
        return LiveCheckResult(isLive: !reasons.isEmpty, reasons: reasons, checkedSignals: ["inuse lock files", "open file handles"], openHandles: status)
    }

    private func planCheck(_ folder: URL) async -> LiveCheckResult {
        let base = await liveness(folder)
        let blocking = processes.blockingReasons([Self.processMatcher])
        return LiveCheckResult(isLive: base.isLive || !blocking.isEmpty, reasons: base.reasons + blocking,
                               checkedSignals: base.checkedSignals + ["Copilot CLI processes"], openHandles: base.openHandles)
    }

    // MARK: Guards

    private func locate(_ session: Session) throws -> URL {
        let folder = layout.folder(of: session.id).standardizedFileURL
        guard session.agent == kind, CopilotLayout.isSafeID(session.id),
              session.transcriptURL.standardizedFileURL.deletingLastPathComponent() == folder,
              FileSystem.exists(folder.appendingPathComponent("events.jsonl")) else {
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
