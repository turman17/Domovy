import Foundation

/// Adapter for Zed's Agent Panel. A native thread is one row of `threads.db` plus its row in
/// the sidebar table of Zed's workspace database. Zed has no command for threads, so Domovy
/// deletes those rows itself, the way it does for Cursor: only while Zed is quit and nothing
/// holds either database open, after cloning both into the quarantine, in one transaction per
/// database, checked with `PRAGMA integrity_check`. Never VACUUM. Undo puts the clones back only
/// while Zed has not written to them since.
///
/// Threads of external agents (`agent_id` = `codex-acp`, …) are the other agent's sessions; this
/// adapter leaves them to that agent's adapter, which notes that Zed lists them.
public struct ZedAdapter: AgentAdapter {
    public let kind: AgentKind = .zed
    /// `~/Library/Application Support/Zed`.
    public let root: URL

    let layout: ZedLayout
    let openHandles: any OpenHandleChecker
    let processes: any RunningProcessLister

    public static let acknowledgement = "Undo puts Zed's thread database and workspace database back as they were before this delete, so anything Zed writes to them afterwards (open tabs, layout) would be lost. Domovy refuses to undo once Zed has changed either file; the thread is then gone for good."

    public static let archiveRemark = "Zed keeps this thread as rows in its databases, already compressed with zstd, so there is nothing for Domovy to compress. Archiving in Zed's sense (moving it to Thread History) also saves and removes the thread's worktree, which only Zed can do: use the archive button in Zed's sidebar."

    public init(
        supportDirectory: URL,
        openHandles: any OpenHandleChecker = LibprocOpenHandleChecker(),
        processes: any RunningProcessLister = LibprocProcessLister()
    ) {
        self.root = supportDirectory.standardizedFileURL
        self.layout = ZedLayout(support: self.root)
        self.openHandles = openHandles
        self.processes = processes
    }

    public init(home: URL) {
        self.init(supportDirectory: ZedLayout.home(home), openHandles: LibprocOpenHandleChecker.shared)
    }

    public var processMatcher: ProcessMatcher { ZedLayout.appMatcher }

    // MARK: AgentAdapter

    public func status() async -> AdapterStatus {
        layout.probe()
    }

    public func sessions() async throws -> [Session] {
        if case .notInstalled = layout.probe() { throw AdapterError.notInstalled(kind) }
        let index = ZedIndex.load(layout)
        let live = await databaseLiveness()
        let fallback = FileSystem.modificationDate(of: layout.threadsDatabase) ?? .distantPast
        return index.threads.values.map { thread in
            Session(id: thread.id, agent: kind, title: thread.title, projectPath: thread.folder,
                    lastActive: thread.updatedAt ?? fallback, sizeBytes: thread.bytes,
                    status: live.isLive ? .live : .idle, expiresAt: nil,
                    transcriptURL: thread.row == nil ? layout.workspaceDatabase : layout.threadsDatabase)
        }
        .sorted { $0.lastActive > $1.lastActive }
    }

    public func artifacts(of session: Session) async throws -> [Artifact] {
        let index = ZedIndex.load(layout)
        let thread = try locate(session, in: index)
        var artifacts: [Artifact] = []
        if let row = thread.row {
            artifacts.append(Artifact(url: layout.threadsDatabase, kind: .indexEntry, sizeBytes: row.dataBytes,
                                      note: "The thread (zstd-compressed) in threads.db"))
        }
        if !thread.children.isEmpty {
            let n = thread.children.count
            artifacts.append(Artifact(url: layout.threadsDatabase, kind: .indexEntry, sizeBytes: thread.children.reduce(0) { $0 + $1.dataBytes },
                                      note: "\(n) subagent \(n == 1 ? "thread" : "threads") in threads.db"))
        }
        for row in thread.sidebar {
            artifacts.append(Artifact(url: layout.workspaceDatabase, kind: .indexEntry, sizeBytes: row.bytes,
                                      note: "Entry in Zed's thread sidebar (sidebar_threads)"))
            if let links = index.worktreeLinks[row.threadHex], !links.isEmpty {
                artifacts.append(Artifact(url: layout.workspaceDatabase, kind: .indexEntry, sizeBytes: 0,
                                          note: "\(links.count) archived worktree \(links.count == 1 ? "record" : "records") (thread_archived_worktrees)"))
            }
        }
        return artifacts
    }

    public func liveCheck(_ session: Session) async throws -> LiveCheckResult {
        _ = try locate(session, in: ZedIndex.load(layout))
        return await databaseLiveness()
    }

    public func deletePlan(for session: Session, destination: Destination = .trash) async throws -> Plan {
        if let reason = layout.unknownLayout() { throw AdapterError.readOnly(kind, reason: reason) }
        let index = ZedIndex.load(layout)
        let thread = try locate(session, in: index)
        let ids = [thread.row?.id].compactMap { $0 } + thread.children.map(\.id)
        guard ids.allSatisfy(SafeID.isSafe), thread.sidebar.allSatisfy({ $0.threadHex.allSatisfy(\.isHexDigit) }) else {
            throw AdapterError.unsafeID(kind, id: thread.id)
        }
        let live = SharedDatabaseLiveness.forPlan(await databaseLiveness(), what: "Zed's thread databases")

        var edits: [DatabaseEdit] = []
        if let row = thread.row {
            var rows = [DatabaseEdit.Rows(table: "threads", key: row.id, isPrefix: false, count: 1, bytes: row.dataBytes,
                                          note: "The thread", column: "id")]
            rows += thread.children.map {
                DatabaseEdit.Rows(table: "threads", key: $0.id, isPrefix: false, count: 1, bytes: $0.dataBytes, note: "A subagent thread", column: "id")
            }
            edits.append(DatabaseEdit(database: layout.threadsDatabase, files: layout.threadsFiles, rows: rows, listRemovals: []))
        }
        let hexes = Set(thread.sidebar.map(\.threadHex))
        var sidebarRows: [DatabaseEdit.Rows] = []
        for row in thread.sidebar {
            sidebarRows.append(.init(table: "sidebar_threads", key: row.threadHex, isPrefix: false, count: 1, bytes: row.bytes,
                                     note: "Its entry in Zed's thread sidebar", column: "thread_id", encoding: .hexBlob))
            let links = index.worktreeLinks[row.threadHex] ?? []
            if !links.isEmpty {
                sidebarRows.append(.init(table: "thread_archived_worktrees", key: row.threadHex, isPrefix: false, count: links.count, bytes: 0,
                                         note: "Its links to archived worktrees", column: "thread_id", encoding: .hexBlob))
            }
        }
        let orphans = index.orphanedWorktrees(removing: hexes)
        sidebarRows += orphans.map {
            .init(table: "archived_git_worktrees", key: String($0), isPrefix: false, count: 1, bytes: 0,
                  note: "An archived worktree record no other thread uses", column: "id", encoding: .integer)
        }
        if !sidebarRows.isEmpty {
            edits.append(DatabaseEdit(database: layout.workspaceDatabase, files: layout.workspaceFiles, rows: sidebarRows, listRemovals: []))
        }

        let copy = CleanupPlan.bytes(edits.flatMap(\.files).reduce(Int64(0)) { $0 + FileSystem.size(of: $1) })
        var remarks = [
            "Zed has no command to delete one thread, so Domovy deletes its rows itself, with Zed quit. First it keeps a copy of \(edits.count == 1 ? "the database" : "both databases") (\(copy)) in its quarantine; afterwards it checks \(edits.count == 1 ? "it is" : "they are") intact and puts the copy back if not.",
            "The files do not shrink: Domovy never runs VACUUM on Zed's databases. Every other table of Zed's workspace database (panes, editors, trusted folders) stays as it is.",
        ]
        if !orphans.isEmpty {
            remarks.append("Zed saved the Git state of \(orphans.count == 1 ? "a worktree" : "\(orphans.count) worktrees") this thread archived. Domovy removes Zed's record of it; the commits stay in the repository, but Zed can no longer restore that worktree.")
        }
        if thread.row == nil {
            remarks.append("threads.db has no conversation for this entry, so only the sidebar entry goes.")
        }
        return Plan(agent: kind, sessionID: session.id, action: .delete, destination: destination, moves: [], indexEdits: [],
                    databaseEdits: edits, remarks: remarks, acknowledgement: Self.acknowledgement,
                    mustNotBeRunning: [ZedLayout.appMatcher], liveCheck: live, scope: scope)
    }

    public func archivePlan(for session: Session) async throws -> Plan {
        _ = try locate(session, in: ZedIndex.load(layout))
        return Plan(agent: kind, sessionID: session.id, action: .archive, destination: nil, moves: [], indexEdits: [],
                    remarks: [Self.archiveRemark], liveCheck: await databaseLiveness(), scope: scope)
    }

    public func transcript(of session: Session, limit: Int, masking findings: [SecretFinding]) async throws -> Transcript {
        let thread = try locate(session, in: ZedIndex.load(layout))
        guard let row = thread.row else { return .empty }
        return ZedIndex.transcript(try ZedIndex.jsonData(of: row.id, in: layout), limit: limit)
    }

    public func footprint() async throws -> Footprint {
        guard FileSystem.isDirectory(root) else { throw AdapterError.notInstalled(kind) }
        let index = ZedIndex.load(layout)
        var builder = FootprintBuilder(agent: kind, root: root)
        let n = index.threads.count
        builder.add("Agent threads", layout.threadsFiles, reveal: layout.threadsFolder, .consequences,
                    "\(n) \(n == 1 ? "thread" : "threads") of Zed's own agent. Delete them one by one in Sessions with Zed quit.",
                    guidance: .manageInSessions)
        builder.add("Old thread store", layout.legacyThreads, .consequences,
                    "The store Zed used before threads.db (threads-db.1.mdb). Zed no longer writes it; it may still hold old threads.")
        builder.add("External agents", root.appendingPathComponent("external_agents", isDirectory: true), .safe,
                    "Installs of external agents such as codex-acp. Zed downloads them again when you use them; their conversations live in each agent's own folder.")
        builder.add("Hang traces", root.appendingPathComponent("hang_traces", isDirectory: true), .safe,
                    "Diagnostic traces Zed wrote when it stopped responding.")
        builder.add("App data", builder.unclaimedChildren(of: root), reveal: root, .keep,
                    "Zed's workspace database, language servers, extensions and Copilot's edit-prediction server. Zed needs them.")
        return builder.build()
    }

    // MARK: Liveness

    private func databaseLiveness() async -> LiveCheckResult {
        await SharedDatabaseLiveness.check(app: ZedLayout.appMatcher, files: layout.databaseFiles, what: "Zed's thread databases",
                                           processes: processes, openHandles: openHandles)
    }

    // MARK: Guards

    private func locate(_ session: Session, in index: ZedIndex) throws -> ZedIndex.Thread {
        guard session.agent == kind, let thread = index.threads[session.id.lowercased()] else {
            throw AdapterError.sessionNotFound(session.id)
        }
        return thread
    }
}
