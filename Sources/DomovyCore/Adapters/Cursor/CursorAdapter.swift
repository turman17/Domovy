import Foundation

/// Adapter for Cursor. Editor chats are rows of one shared SQLite database, `state.vscdb`, and
/// Cursor has no command to delete one chat, so Domovy deletes the rows itself: only while
/// Cursor is fully quit and nothing holds the database open, after cloning the whole database
/// into the quarantine, in one transaction, and checked with `PRAGMA integrity_check` (the
/// clone goes back if that fails). Never VACUUM. Undo puts the clone back only while Cursor has
/// not written to the database since. CLI chats are folders: delete moves them, archive
/// compresses them. Editor chats have no archive: no file belongs to one chat.
public struct CursorAdapter: AgentAdapter {
    public let kind: AgentKind = .cursor
    /// `Application Support/Cursor`.
    public let root: URL

    let layout: CursorLayout
    let openHandles: any OpenHandleChecker
    let processes: any RunningProcessLister

    public static let acknowledgement = "Undo puts Cursor's whole database (state.vscdb) back as it was before this delete, so anything Cursor writes to it afterwards would be lost. Domovy refuses to undo once Cursor has changed the file; the chat is then gone for good."

    public static let spaceRemark = "The file does not shrink: Domovy never runs VACUUM on Cursor's database. Cursor reclaims the space on its own or with Developer: GC Agent KV Blobs."

    /// - Parameters:
    ///   - supportDirectory: `~/Library/Application Support/Cursor`. Tests pass a fixture copy.
    ///   - dotDirectory: `~/.cursor`, for CLI chats.
    public init(
        supportDirectory: URL,
        dotDirectory: URL,
        openHandles: any OpenHandleChecker = LibprocOpenHandleChecker(),
        processes: any RunningProcessLister = LibprocProcessLister()
    ) {
        self.root = supportDirectory.standardizedFileURL
        self.layout = CursorLayout(support: self.root, dot: dotDirectory.standardizedFileURL)
        self.openHandles = openHandles
        self.processes = processes
    }

    /// Convenience for a home directory.
    public init(home: URL) {
        self.init(supportDirectory: home.appendingPathComponent("Library/Application Support/Cursor", isDirectory: true),
                  dotDirectory: home.appendingPathComponent(".cursor", isDirectory: true))
    }

    /// `Application Support/Cursor` and `~/.cursor` (CLI chats, plain-text copies).
    public var scope: [URL] { [layout.support, layout.dot] }

    /// The Cursor app, which must be quit before its database changes.
    public var processMatcher: ProcessMatcher { CursorLayout.appMatcher }

    /// An editor chat (rows in `state.vscdb`), as opposed to a CLI chat folder.
    public static func isEditorChat(_ session: Session) -> Bool {
        session.agent == .cursor && session.transcriptURL.lastPathComponent == "state.vscdb"
    }

    // MARK: AgentAdapter

    public func status() async -> AdapterStatus {
        layout.probe()
    }

    public func sessions() async throws -> [Session] {
        if case .notInstalled = layout.probe() { throw AdapterError.notInstalled(kind) }
        var result: [Session] = []
        if let index = CursorIndex.load(layout) {
            let live = await databaseLiveness()
            let fallback = FileSystem.modificationDate(of: layout.database) ?? .distantPast
            result += index.chats.values.map { chat in
                Session(id: chat.id, agent: kind, title: chat.title, projectPath: chat.workspace,
                        lastActive: chat.updatedAt ?? chat.createdAt ?? fallback, sizeBytes: chat.bytes + transcriptBytes(of: chat.id),
                        status: live.isLive ? .live : .idle, expiresAt: nil, transcriptURL: layout.database)
            }
        }
        for folder in layout.cliChatFolders() {
            result.append(await makeCLISession(folder))
        }
        return result.sorted { $0.lastActive > $1.lastActive }
    }

    public func artifacts(of session: Session) async throws -> [Artifact] {
        switch try locate(session) {
        case .editor(let chat):
            var artifacts = CursorIndex.rows(of: chat.id, in: layout).map { rows in
                Artifact(url: layout.database, kind: .indexEntry, sizeBytes: rows.bytes, note: "\(rows.note): \(rows.count) \(rows.count == 1 ? "row" : "rows") in state.vscdb")
            }
            if chat.isListed {
                artifacts.append(Artifact(url: layout.database, kind: .indexEntry, sizeBytes: 0, note: "Entry in Cursor's chat list (composer.composerHeaders)"))
            }
            artifacts += agentTranscripts(of: chat.id).map { Artifact(url: $0, kind: .file, sizeBytes: FileSystem.size(of: $0), note: "Plain-text copy of the chat") }
            return artifacts
        case .cli(let folder):
            return [Artifact(url: folder, kind: .folder, sizeBytes: FileSystem.size(of: folder), note: "CLI chat folder")]
        }
    }

    public func liveCheck(_ session: Session) async throws -> LiveCheckResult {
        switch try locate(session) {
        case .editor: await databaseLiveness()
        case .cli(let folder): await cliLiveness(folder)
        }
    }

    public func deletePlan(for session: Session, destination: Destination = .trash) async throws -> Plan {
        switch try locate(session) {
        case .editor(let chat): try await editorDeletePlan(chat, session: session, destination: destination)
        case .cli(let folder): await cliDeletePlan(folder, session: session, destination: destination)
        }
    }

    public func archivePlan(for session: Session) async throws -> Plan {
        switch try locate(session) {
        case .editor:
            return Plan(agent: kind, sessionID: session.id, action: .archive, destination: nil, moves: [], indexEdits: [],
                        remarks: ["Cursor keeps this chat as rows inside state.vscdb, so there is no file of it to compress. Domovy leaves the database as it is."],
                        liveCheck: await databaseLiveness(), scope: self.scope)
        case .cli(let folder):
            var compressions: [FileCompression] = []
            for file in APFSCompression.regularFiles(at: folder) {
                guard layout.isCLIChatFolder(folder), !file.lastPathComponent.hasSuffix("-wal"), !file.lastPathComponent.hasSuffix("-shm"),
                      !APFSCompression.isCompressed(file), FileSystem.size(of: file) > APFSCompression.minimumUsefulSize else { continue }
                compressions.append(FileCompression(
                    file: file, sizeBytes: APFSCompression.allocatedBytes(of: file),
                    estimatedBytes: APFSCompression.estimatedCompressedBytes(of: file),
                    modificationTime: FileSystem.modificationTime(of: file), note: "CLI chat file"
                ))
            }
            return Plan(agent: kind, sessionID: session.id, action: .archive, destination: nil, moves: [], indexEdits: [],
                        compressions: compressions, liveCheck: await cliLiveness(folder), scope: self.scope)
        }
    }

    public func transcript(of session: Session, limit: Int, masking findings: [SecretFinding]) async throws -> Transcript {
        switch try locate(session) {
        case .editor(let chat): CursorIndex.transcript(layout, id: chat.id, limit: limit)
        case .cli: .empty
        }
    }

    public func footprint() async throws -> Footprint {
        let index = CursorIndex.load(layout)
        let summary = index.map { index in
            CursorFootprint.ChatSummary(chats: index.chats.count, bytes: index.chats.values.reduce(0) { $0 + $1.bytes },
                                        cliChats: layout.cliChatFolders().count)
        }
        return try await CursorFootprint(supportDirectory: layout.support, dotDirectory: layout.dot).footprint(summary: summary)
    }

    // MARK: Delete

    private func editorDeletePlan(_ chat: CursorIndex.Chat, session: Session, destination: Destination) async throws -> Plan {
        if case .unknown(let reason) = layout.databaseState() { throw AdapterError.readOnly(kind, reason: reason) }
        // Rows go by the prefix `<kind>:<id>:`, which would also match a chat `<id>:<more>`, and
        // the id names a file in ~/.cursor/projects. Only plain ids are deleted.
        guard SafeID.isSafe(chat.id), !CursorIndex.hasLongerIDs(of: chat.id, in: layout) else {
            throw AdapterError.unsafeID(kind, id: chat.id)
        }
        let live = await planCheck()
        let listings = CursorIndex.workspaceListings(of: chat.id, in: layout)
        guard listings.isEmpty else {
            let n = listings.count
            return Plan(agent: kind, sessionID: session.id, action: .delete, destination: destination, moves: [], indexEdits: [],
                        remarks: ["\(n) workspace \(n == 1 ? "database lists" : "databases list") this chat too (an older Cursor layout). Domovy does not edit those, and the chat would come back, so nothing will change. Delete it in Cursor instead."],
                        liveCheck: live, scope: self.scope)
        }
        let index = CursorIndex.load(layout)
        var removals: [DatabaseEdit.ListEntryRemoval] = []
        if case .known(let field, let entries)? = index?.headers, entries[chat.id] != nil {
            removals.append(.init(table: "ItemTable", key: CursorLayout.headersKey, listField: field, idField: CursorHeaders.idField,
                                  id: chat.id, note: "Its entry in Cursor's chat list; the other entries stay byte for byte"))
        }
        let edit = DatabaseEdit(database: layout.database, files: layout.databaseFiles, rows: CursorIndex.rows(of: chat.id, in: layout), listRemovals: removals)
        let moves = agentTranscripts(of: chat.id).map { FileMove(source: $0, kind: .file, sizeBytes: FileSystem.size(of: $0), note: "Plain-text copy of the chat") }

        let copy = CleanupPlan.bytes(layout.databaseFiles.reduce(Int64(0)) { $0 + FileSystem.size(of: $1) })
        var remarks = [
            "Cursor has no command to delete one chat, so Domovy deletes its rows from state.vscdb itself, with Cursor quit. First it keeps a copy of the whole database (\(copy)) in its quarantine; afterwards it checks the database is intact and puts the copy back if not.",
            Self.spaceRemark,
        ]
        if let shared = index?.sharedAgentKvRows, shared > 0 {
            remarks.append("\(shared) agentKv \(shared == 1 ? "row belongs" : "rows belong") to no one chat, so Domovy leaves \(shared == 1 ? "it" : "them"). GC Agent KV Blobs in Cursor removes the ones no chat uses any more.")
        }
        if chat.subChats > 0 {
            remarks.append("This chat has \(chat.subChats) sub-\(chat.subChats == 1 ? "chat" : "chats"); Domovy leaves \(chat.subChats == 1 ? "it" : "them") in Sessions.")
        }
        if FileSystem.exists(layout.backup) {
            remarks.append("state.vscdb.backup is an older copy Cursor no longer updates and may still hold this chat. Domovy leaves it; you can remove it with Cursor quit.")
        }
        return Plan(agent: kind, sessionID: session.id, action: .delete, destination: destination, moves: moves, indexEdits: [],
                    databaseEdits: [edit], remarks: remarks, acknowledgement: Self.acknowledgement,
                    mustNotBeRunning: [CursorLayout.appMatcher], liveCheck: live, scope: self.scope)
    }

    private func cliDeletePlan(_ folder: URL, session: Session, destination: Destination) async -> Plan {
        let move = FileMove(source: folder, kind: .folder, sizeBytes: FileSystem.size(of: folder), note: "CLI chat folder")
        let base = await cliLiveness(folder)
        let blocking = processes.blockingReasons([layout.cliMatcher()])
        let live = LiveCheckResult(isLive: base.isLive || !blocking.isEmpty, reasons: base.reasons + blocking,
                                   checkedSignals: base.checkedSignals + ["Cursor CLI processes"], openHandles: base.openHandles)
        return Plan(agent: kind, sessionID: session.id, action: .delete, destination: destination, moves: [move], indexEdits: [],
                    mustNotBeRunning: [layout.cliMatcher()], liveCheck: live, scope: self.scope)
    }

    /// `~/.cursor/projects/<project>/agent-transcripts/<chat id>.txt`: plain-text copies Cursor
    /// writes and never reads (reported).
    private func agentTranscripts(of id: String) -> [URL] {
        FileSystem.children(of: layout.dot.appendingPathComponent("projects", isDirectory: true)).compactMap { project in
            let file = project.appendingPathComponent("agent-transcripts/\(id).txt")
            return FileSystem.exists(file) ? file : nil
        }
    }

    private func transcriptBytes(of id: String) -> Int64 {
        agentTranscripts(of: id).reduce(0) { $0 + FileSystem.size(of: $1) }
    }

    // MARK: Sessions

    private func makeCLISession(_ folder: URL) async -> Session {
        let header = CursorCLIChats.header(of: folder)
        let store = CursorCLIChats.store(of: folder)
        let live = await cliLiveness(folder)
        let archived = APFSCompression.isCompressed(store)
        return Session(id: folder.lastPathComponent, agent: kind, title: header.title, projectPath: nil,
                       lastActive: CursorCLIChats.lastActive(of: folder), sizeBytes: FileSystem.size(of: folder),
                       status: live.isLive ? .live : archived ? .archived : .idle, expiresAt: nil,
                       transcriptURL: store, isArchived: archived)
    }

    // MARK: Liveness

    /// Every editor chat shares one database, so while Cursor runs or anything holds the
    /// database open, Domovy cannot tell which chat is in use: all of them count as live.
    private func databaseLiveness() async -> LiveCheckResult {
        var reasons: [String] = []
        let running = processes.blockingReasons([CursorLayout.appMatcher])
        if !running.isEmpty {
            reasons += running
            reasons.append("Every Cursor chat lives in one shared database, so Domovy treats all of them as in use while Cursor runs.")
        }
        let status: LiveCheckResult.OpenHandleStatus
        if let holders = await openHandles.holders(of: layout.databaseFiles, includingMapped: true) {
            status = holders.isEmpty ? .clear : .open
            var seen = Set<Int32>()
            for holder in holders where seen.insert(holder.pid).inserted {
                reasons.append("\(holder.processName) (pid \(holder.pid)) has Cursor's chat database open, so Domovy cannot tell which chat it uses.")
            }
        } else {
            status = .unavailable
        }
        return LiveCheckResult(isLive: !reasons.isEmpty, reasons: reasons, checkedSignals: ["Cursor processes", "open file handles"], openHandles: status)
    }

    private func planCheck() async -> LiveCheckResult {
        let base = await databaseLiveness()
        guard base.openHandles != .unavailable else {
            // Domovy must be sure nothing has the database open before it writes to it.
            return LiveCheckResult(isLive: true, reasons: base.reasons + ["Domovy could not check which processes have Cursor's database open, so it changes nothing."],
                                   checkedSignals: base.checkedSignals, openHandles: base.openHandles)
        }
        return base
    }

    private func cliLiveness(_ folder: URL) async -> LiveCheckResult {
        var reasons: [String] = []
        let status: LiveCheckResult.OpenHandleStatus
        if let holders = await openHandles.holders(of: [folder]) {
            status = holders.isEmpty ? .clear : .open
            var seen = Set<Int32>()
            for holder in holders where seen.insert(holder.pid).inserted {
                reasons.append("\(holder.processName) (pid \(holder.pid)) has a file of this chat open.")
            }
        } else {
            status = .unavailable
        }
        return LiveCheckResult(isLive: !reasons.isEmpty, reasons: reasons, checkedSignals: ["open file handles"], openHandles: status)
    }

    // MARK: Guards

    private enum Located {
        case editor(CursorIndex.Chat)
        case cli(URL)
    }

    private func locate(_ session: Session) throws -> Located {
        guard session.agent == kind else { throw AdapterError.sessionNotFound(session.id) }
        if session.transcriptURL.standardizedFileURL == layout.database.standardizedFileURL {
            guard let chat = CursorIndex.load(layout)?.chats[session.id] else { throw AdapterError.sessionNotFound(session.id) }
            return .editor(chat)
        }
        let folder = session.transcriptURL.standardizedFileURL.deletingLastPathComponent()
        guard layout.isCLIChatFolder(folder), folder.lastPathComponent == session.id, FileSystem.isDirectory(folder) else {
            throw AdapterError.sessionNotFound(session.id)
        }
        return .cli(folder)
    }
}
