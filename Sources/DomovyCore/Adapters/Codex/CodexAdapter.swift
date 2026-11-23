import Foundation

/// Adapter for Codex CLI and the Codex app (`~/.codex`, or `$CODEX_HOME`). See PLAN.md section 5.
/// Delete and archive run Codex's own `codex delete` / `codex archive` when the CLI supports
/// them (safety rule 3) and verify the result; without it, files move to the Trash and
/// `session_index.jsonl` is edited with a backup. Codex's SQLite databases are only ever read.
public struct CodexAdapter: AgentAdapter {
    public let kind: AgentKind = .codex
    public let root: URL

    let layout: CodexLayout
    let openHandles: any OpenHandleChecker
    let processes: any RunningProcessLister
    let cli: CodexCLIResolver

    /// Any Codex process (the CLI, the app-server daemon, the desktop app and its helpers) that
    /// has a file open in this adapter's CODEX_HOME. The ChatGPT app keeps an app-server running
    /// all the time; it only blocks a change when it is using this very folder.
    public var processMatcher: ProcessMatcher {
        ProcessMatcher(
            appName: "Codex",
            names: ["codex"],
            prefixes: ["codex-"],
            scope: root,
            quitAdvice: "Quit the ChatGPT app or Codex to change this session."
        )
    }

    /// - Parameters:
    ///   - codexHome: the `.codex` folder to scan. Tests pass a copy of a fixture.
    ///   - cli: which `codex` to run for delete and archive; tests pass a stub.
    ///   - openHandles: open-file-handle check; libproc by default, a stub in tests.
    ///   - processes: running-Codex check before anything touches its index.
    public init(
        codexHome: URL,
        cli: CodexCLI.Choice = .automatic,
        openHandles: any OpenHandleChecker = LibprocOpenHandleChecker(),
        processes: any RunningProcessLister = LibprocProcessLister()
    ) {
        self.root = codexHome.standardizedFileURL
        self.layout = CodexLayout(root: self.root)
        self.openHandles = openHandles
        self.processes = processes
        self.cli = CodexCLIResolver(choice: cli, codexHome: self.root)
    }

    /// Convenience for a home directory: `<home>/.codex`.
    public init(home: URL, cli: CodexCLI.Choice = .automatic) {
        self.init(codexHome: home.appendingPathComponent(".codex", isDirectory: true), cli: cli)
    }

    /// The `codex` executable plans will run, or `nil` when they fall back to moving files.
    public var commandLineTool: CodexCLI? { cli.resolve() }

    // MARK: AgentAdapter

    public func status() async -> AdapterStatus {
        layout.probe()
    }

    public func sessions() async throws -> [Session] {
        if case .notInstalled = layout.probe() { throw AdapterError.notInstalled(kind) }
        let index = CodexIndex.load(layout)
        var result: [Session] = []
        for (id, files) in groupedRollouts() {
            result.append(await makeSession(id: id, files: files, index: index))
        }
        return result.sorted { $0.lastActive > $1.lastActive }
    }

    public func artifacts(of session: Session) async throws -> [Artifact] {
        try requireOurs(session)
        return collectArtifacts(id: session.id)
    }

    public func liveCheck(_ session: Session) async throws -> LiveCheckResult {
        try requireOurs(session)
        return await liveness(id: session.id, files: rollouts(of: session.id))
    }

    public func deletePlan(for session: Session, destination: Destination = .trash) async throws -> Plan {
        try requireOurs(session)
        try requireWritable()
        let id = session.id
        let rollouts = rollouts(of: id)
        let images = layout.generatedImages.appendingPathComponent(id, isDirectory: true)
        let companions = FileSystem.exists(images) ? [images] : []
        for url in rollouts + companions where layout.isProtected(url) { throw AdapterError.protectedPathInPlan(url) }

        let sessionEdit = CodexIndex.edit(layout.sessionIndex, key: CodexIndex.sessionIndexKey, id: id)
        let historyEdit = CodexIndex.edit(layout.history, key: CodexIndex.historyKey, id: id)
        let rows = CodexIndex.databaseRows(root: root, id: id)
        let check = await planCheck(id: id, files: rollouts, touchesIndex: true)
        let rolloutBytes = rollouts.reduce(Int64(0)) { $0 + FileSystem.size(of: $1) }

        var moves = companions.map { FileMove(source: $0, kind: .folder, sizeBytes: FileSystem.size(of: $0), note: ArtifactNote.images) }
        var edits = [historyEdit].compactMap { $0 }
        var commands: [PlannedCommand] = []
        var remarks: [String] = []

        if let tool = cli.resolve(), tool.supportsDelete {
            // Every database row that references the thread is checked; what stays is reported.
            var checks: [Verification] = rollouts.map { .fileGone($0) }
            checks.append(.linesGone(file: layout.sessionIndex, key: CodexIndex.sessionIndexKey, value: id))
            for db in rows {
                for table in db.tables { checks.append(.rowsGone(database: db.database, table: table.table, column: table.column, value: id)) }
            }
            commands.append(PlannedCommand(
                executable: tool.executable,
                arguments: ["delete", "--force", id],
                environment: ["CODEX_HOME": root.path],
                note: "Runs `codex delete` for this session, then checks the result.",
                copiesBeforeRun: rollouts,
                indexLinesBeforeRun: [sessionEdit].compactMap { $0 },
                verifications: checks,
                sizeBytes: rolloutBytes + (sessionEdit?.removedBytes ?? 0)
            ))
            remarks.append("Codex deletes the rollout itself. Domovy keeps a copy in its quarantine folder, so undo can put the file back; Codex's database rows do not come back.")
        } else {
            moves = rollouts.map { FileMove(source: $0, kind: .file, sizeBytes: FileSystem.size(of: $0), note: Self.note(forRollout: $0)) } + moves
            edits = [sessionEdit].compactMap { $0 } + edits
            if !rows.isEmpty {
                let total = rows.reduce(0) { $0 + $1.total }
                let names = rows.map(\.database.lastPathComponent).joined(separator: ", ")
                remarks.append("\(total) \(total == 1 ? "row stays" : "rows stay") in \(names). Domovy never edits Codex's databases, so Codex may still list this session. \(Self.cliHint)")
            }
        }
        return Plan(
            agent: kind,
            sessionID: id,
            action: .delete,
            destination: destination,
            moves: moves,
            indexEdits: edits,
            commands: commands,
            remarks: remarks,
            mustNotBeRunning: [processMatcher],
            liveCheck: check
        )
    }

    /// With the CLI: `codex archive` moves the rollout to `archived_sessions/` and marks the
    /// thread archived; undo runs `codex unarchive`. Without it: APFS compression in place,
    /// which leaves Codex's index alone.
    public func archivePlan(for session: Session) async throws -> Plan {
        try requireOurs(session)
        try requireWritable()
        let id = session.id
        let active = rollouts(of: id).filter { FileSystem.relativePath(of: $0, under: layout.sessions) != nil }
        guard !session.isArchived, !active.isEmpty else {
            return Plan(agent: kind, sessionID: id, action: .archive, destination: nil, moves: [], indexEdits: [],
                        remarks: ["This session is already in archived_sessions."],
                        liveCheck: await liveness(id: id, files: rollouts(of: id)))
        }
        for url in active where layout.isProtected(url) { throw AdapterError.protectedPathInPlan(url) }

        if let tool = cli.resolve(), tool.supportsArchive {
            let environment = ["CODEX_HOME": root.path]
            let unarchive = PlannedCommand(
                executable: tool.executable,
                arguments: ["unarchive", id],
                environment: environment,
                note: "Runs `codex unarchive` to bring it back."
            )
            let command = PlannedCommand(
                executable: tool.executable,
                arguments: ["archive", id],
                environment: environment,
                note: "Runs `codex archive`, which moves this session to archived_sessions and hides it from Codex's list, then checks the result.",
                verifications: active.map { .fileGone($0) } + [.fileAppears(directory: layout.archivedSessions, nameContaining: id)],
                sizeBytes: active.reduce(Int64(0)) { $0 + FileSystem.size(of: $1) },
                undo: [unarchive]
            )
            return Plan(agent: kind, sessionID: id, action: .archive, destination: nil, moves: [], indexEdits: [],
                        commands: [command],
                        remarks: ["Codex can still open it from its archive."],
                        mustNotBeRunning: [processMatcher],
                        liveCheck: await planCheck(id: id, files: active, touchesIndex: true))
        }

        var compressions: [FileCompression] = []
        for file in active where !file.lastPathComponent.hasSuffix(".zst") {
            guard APFSCompression.isRegularFile(file), !APFSCompression.isCompressed(file),
                  FileSystem.size(of: file) > APFSCompression.minimumUsefulSize else { continue }
            compressions.append(FileCompression(
                file: file,
                sizeBytes: APFSCompression.allocatedBytes(of: file),
                estimatedBytes: APFSCompression.estimatedCompressedBytes(of: file),
                modificationTime: FileSystem.modificationTime(of: file),
                note: Self.note(forRollout: file)
            ))
        }
        return Plan(agent: kind, sessionID: id, action: .archive, destination: nil, moves: [], indexEdits: [],
                    compressions: compressions,
                    remarks: ["The codex CLI was not found, so Domovy compresses the rollout in place instead of moving it to archived_sessions."],
                    liveCheck: await planCheck(id: id, files: active, touchesIndex: false))
    }

    public func transcript(of session: Session, limit: Int) async throws -> Transcript {
        try requireOurs(session)
        return try CodexRollout.readTranscript(of: session.transcriptURL, maxMessages: limit)
    }

    // MARK: Building sessions

    private func makeSession(id: String, files: [URL], index: CodexIndex) async -> Session {
        let main = Self.primary(of: files)
        let header = CodexRollout.readHeader(of: main)
        let thread = index.threads[id]
        let images = layout.generatedImages.appendingPathComponent(id, isDirectory: true)
        let size = (files + [images]).reduce(Int64(0)) { $0 + FileSystem.size(of: $1) }
            + (index.sessionIndexLines[id]?.bytes ?? 0) + (index.historyLines[id]?.bytes ?? 0)
        let lastActive = files.compactMap(FileSystem.modificationDate).max() ?? .distantPast
        let archived = FileSystem.relativePath(of: main, under: layout.archivedSessions) != nil
        let live = await liveness(id: id, files: files)
        return Session(
            id: id,
            agent: kind,
            title: index.names[id] ?? thread?.title ?? header.title,
            projectPath: header.cwd ?? thread?.cwd,
            lastActive: lastActive,
            sizeBytes: size,
            status: live.isLive ? .live : (archived ? .archived : .idle),
            expiresAt: nil,
            transcriptURL: main,
            isArchived: archived
        )
    }

    /// Rollouts grouped by thread id; one thread may have segment files and a `.zst` twin.
    private func groupedRollouts() -> [String: [URL]] {
        let files = layout.rolloutFiles()
        var groups: [String: [URL]] = [:]
        for file in files.active + files.archived {
            guard let name = CodexLayout.rolloutName(file.lastPathComponent) else { continue }
            groups[name.threadID, default: []].append(file)
        }
        return groups
    }

    private func rollouts(of id: String) -> [URL] {
        groupedRollouts()[id.lowercased()] ?? []
    }

    /// The thread's own rollout (not a segment), plain before `.zst`.
    private static func primary(of files: [URL]) -> URL {
        let ranked = files.sorted { a, b in
            func rank(_ url: URL) -> Int {
                guard let name = CodexLayout.rolloutName(url.lastPathComponent) else { return 9 }
                return (name.segmentID == nil ? 0 : 2) + (name.isCompressed ? 1 : 0)
            }
            return (rank(a), a.lastPathComponent) < (rank(b), b.lastPathComponent)
        }
        return ranked[0]
    }

    // MARK: Artifacts

    private func collectArtifacts(id: String) -> [Artifact] {
        var artifacts: [Artifact] = []
        for file in rollouts(of: id) where !layout.isProtected(file) {
            artifacts.append(Artifact(url: file, kind: .file, sizeBytes: FileSystem.size(of: file), note: Self.note(forRollout: file)))
        }
        let images = layout.generatedImages.appendingPathComponent(id, isDirectory: true)
        if FileSystem.exists(images) {
            artifacts.append(Artifact(url: images, kind: .folder, sizeBytes: FileSystem.size(of: images), note: ArtifactNote.images))
        }
        for edit in [CodexIndex.edit(layout.sessionIndex, key: CodexIndex.sessionIndexKey, id: id),
                     CodexIndex.edit(layout.history, key: CodexIndex.historyKey, id: id)].compactMap({ $0 }) {
            artifacts.append(Artifact(url: edit.file, kind: .indexEntry, sizeBytes: edit.removedBytes, note: edit.note))
        }
        for rows in CodexIndex.databaseRows(root: root, id: id) {
            artifacts.append(Artifact(url: rows.database, kind: .indexEntry, sizeBytes: 0, note: rows.note))
        }
        return artifacts
    }

    private static func note(forRollout url: URL) -> String {
        guard let name = CodexLayout.rolloutName(url.lastPathComponent) else { return ArtifactNote.rollout }
        if name.segmentID != nil { return name.isCompressed ? "Rollout segment (zstd)" : "Rollout segment" }
        return name.isCompressed ? "Rollout (zstd)" : ArtifactNote.rollout
    }

    // MARK: Liveness

    /// Live when a process holds a rollout or the thread's writer lock open.
    private func liveness(id: String, files: [URL]) async -> LiveCheckResult {
        let lock = layout.writerLock(for: id)
        var reasons: [String] = []
        let status: LiveCheckResult.OpenHandleStatus
        if let holders = await openHandles.holders(of: files + [lock]) {
            status = holders.isEmpty ? .clear : .open
            var seen = Set<Int32>()
            let lockPaths = Set([lock.path, lock.resolvingSymlinksInPath().path])
            for holder in holders where seen.insert(holder.pid).inserted {
                if lockPaths.contains(holder.path) || holder.path.hasSuffix("/thread-writer-locks/\(id).lock") {
                    reasons.append("Codex has this session open (\(holder.processName), pid \(holder.pid)). Close it in Codex first.")
                } else {
                    reasons.append("\(holder.processName) (pid \(holder.pid)) has a file of this session open.")
                }
            }
        } else {
            status = .unavailable
        }
        return LiveCheckResult(isLive: !reasons.isEmpty, reasons: reasons, checkedSignals: ["open file handles", "thread-writer-locks"], openHandles: status)
    }

    /// The session's liveness, plus "Codex is running" when the plan touches Codex's index.
    private func planCheck(id: String, files: [URL], touchesIndex: Bool) async -> LiveCheckResult {
        let base = await liveness(id: id, files: files)
        guard touchesIndex else { return base }
        let blocking = processes.blockingReasons([processMatcher])
        return LiveCheckResult(
            isLive: base.isLive || !blocking.isEmpty,
            reasons: base.reasons + blocking,
            checkedSignals: base.checkedSignals + ["Codex processes"],
            openHandles: base.openHandles
        )
    }

    // MARK: Guards

    private static let stateDatabase = CodexLayout.stateDatabaseName
    private static let cliHint = "With the codex CLI installed, Domovy runs `codex delete` instead, which removes them."

    private func requireWritable() throws {
        switch layout.probe() {
        case .readOnly(let reason): throw AdapterError.readOnly(kind, reason: reason)
        case .notInstalled: throw AdapterError.notInstalled(kind)
        case .ready: break
        }
    }

    private func requireOurs(_ session: Session) throws {
        guard session.agent == kind, FileSystem.relativePath(of: session.transcriptURL, under: root) != nil else {
            throw AdapterError.sessionNotFound(session.id)
        }
    }
}

private enum ArtifactNote {
    static let rollout = "Rollout"
    static let images = "Generated images"
}
