import Foundation

/// Adapter for agents with one JSON-lines file per session (see `JSONLSessionFlavor`). Delete
/// moves the file and its companions to the Trash or the quarantine; archive compresses them in
/// place, which the agent reads unchanged. Both need the agent quit.
public struct JSONLSessionAdapter: AgentAdapter {
    public let flavor: JSONLSessionFlavor
    public var kind: AgentKind { flavor.kind }
    public let root: URL

    let layout: JSONLSessionLayout
    let openHandles: any OpenHandleChecker
    let processes: any RunningProcessLister

    /// - Parameter folder: the agent's folder (`~/.augment`). Tests pass a copy of a fixture.
    public init(folder: URL, flavor: JSONLSessionFlavor, openHandles: any OpenHandleChecker = LibprocOpenHandleChecker(),
                processes: any RunningProcessLister = LibprocProcessLister()) {
        self.flavor = flavor
        self.root = folder.standardizedFileURL
        self.layout = JSONLSessionLayout(flavor: flavor, root: self.root)
        self.openHandles = openHandles
        self.processes = processes
    }

    public init(home: URL, flavor: JSONLSessionFlavor) {
        self.init(folder: home.appendingPathComponent(flavor.folder, isDirectory: true), flavor: flavor, openHandles: LibprocOpenHandleChecker.shared)
    }

    // MARK: AgentAdapter

    public func status() async -> AdapterStatus { layout.probe() }

    public func sessions() async throws -> [Session] {
        if case .notInstalled = layout.probe() { throw AdapterError.notInstalled(kind) }
        let chats = layout.chats().compactMap { chat in layout.header(of: chat.file).map { (chat, $0) } }
        let holders = await openHandleHolders(of: chats.map { files(of: $0.0) }, checker: openHandles)
        return zip(chats, holders).map { pair, holders in
            makeSession(pair.0, header: pair.1, live: FileSessions.liveness(markers: [], holders: holders, signals: []))
        }
        .sorted { $0.lastActive > $1.lastActive }
    }

    public func artifacts(of session: Session) async throws -> [Artifact] {
        collectArtifacts(try locate(session))
    }

    public func liveCheck(_ session: Session) async throws -> LiveCheckResult {
        guard let result = await liveChecks(for: [session]).first else { throw AdapterError.sessionNotFound(session.id) }
        return try result.get()
    }

    public func liveChecks(for sessions: [Session]) async -> [Result<LiveCheckResult, any Error>] {
        await FileSessions.liveChecks(for: sessions, checker: openHandles, locate: locate, files: files(of:),
                                      liveness: { FileSessions.liveness(markers: [], holders: $1, signals: []) })
    }

    public func deletePlan(for session: Session, destination: Destination = .trash) async throws -> Plan {
        guard let planned = await deletePlans(for: [session], destination: destination).first else { throw AdapterError.sessionNotFound(session.id) }
        return try planned.result.get()
    }

    public func deletePlans(for sessions: [Session], destination: Destination) async -> [PlannedSession] {
        let writable = Result { try requireWritable() }
        let blocking = processes.blockingReasons([flavor.matcher])
        return await FileSessions.plans(
            for: sessions, checker: openHandles, locate: locate, files: files(of:),
            liveness: { FileSessions.liveness(markers: [], holders: $1, signals: []) },
            finish: { session, chat, live in
                try writable.get()
                let artifacts = collectArtifacts(chat)
                for artifact in artifacts where layout.isProtected(artifact.url) { throw AdapterError.protectedPathInPlan(artifact.url) }
                let moves = artifacts.map { FileMove(source: $0.url, kind: $0.kind, sizeBytes: $0.sizeBytes, note: $0.note) }
                return Plan(agent: kind, sessionID: session.id, action: .delete, destination: destination, moves: moves, indexEdits: [],
                            remarks: [flavor.deleteRemark] + flavor.extraDeleteRemarks, mustNotBeRunning: [flavor.matcher],
                            liveCheck: FileSessions.forPlan(live, blocking: blocking, app: flavor.appName), scope: scope)
            })
    }

    public func archivePlan(for session: Session) async throws -> Plan {
        guard let planned = await archivePlans(for: [session]).first else { throw AdapterError.sessionNotFound(session.id) }
        return try planned.result.get()
    }

    /// Compresses the session's files in place; the agent reads them unchanged.
    public func archivePlans(for sessions: [Session]) async -> [PlannedSession] {
        let writable = Result { try requireWritable() }
        let blocking = processes.blockingReasons([flavor.matcher])
        return await FileSessions.plans(
            for: sessions, checker: openHandles, locate: locate, files: files(of:),
            liveness: { FileSessions.liveness(markers: [], holders: $1, signals: []) },
            finish: { session, chat, live in
                try writable.get()
                let compressions = try FileSessions.compressions(of: collectArtifacts(chat), isProtected: layout.isProtected)
                return Plan(agent: kind, sessionID: session.id, action: .archive, destination: nil, moves: [], indexEdits: [],
                            compressions: compressions,
                            remarks: ["\(flavor.appName) has no archive of its own. Domovy compresses the session's files in place; \(flavor.appName) still reads and resumes it."],
                            mustNotBeRunning: [flavor.matcher],
                            liveCheck: FileSessions.forPlan(live, blocking: blocking, app: flavor.appName), scope: scope)
            })
    }

    public func transcript(of session: Session, limit: Int, masking findings: [SecretFinding]) async throws -> Transcript {
        let chat = try locate(session)
        return try FileSessions.readJSONLines(of: chat.file, maxMessages: limit, masking: findings) { record, index in
            JSONLSessionFlavor.message(record, index: index)
        }
    }

    public func transcriptPage(of session: Session, limit: Int, before cursor: TranscriptCursor?, masking findings: [SecretFinding]) async throws -> Transcript {
        let chat = try locate(session)
        return try FileSessions.readJSONLinesPage(of: chat.file, limit: limit, before: cursor, masking: findings) { record, index in
            JSONLSessionFlavor.message(record, index: index)
        }
    }

    // MARK: Sessions

    private func makeSession(_ chat: JSONLSessionLayout.Chat, header: [String: Any], live: LiveCheckResult) -> Session {
        let compressed = APFSCompression.isCompressed(chat.file)
        return Session(
            id: chat.id,
            agent: kind,
            title: flavor.title(header: header, records: FileSessions.records(in: chat.file), tail: FileSessions.tailRecords(in: chat.file)),
            projectPath: (header["cwd"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil },
            lastActive: FileSystem.modificationDate(of: chat.file) ?? .distantPast,
            sizeBytes: collectArtifacts(chat).reduce(0) { $0 + $1.sizeBytes },
            status: live.isLive ? .live : compressed ? .archived : .idle,
            expiresAt: nil,
            transcriptURL: chat.file,
            isArchived: compressed
        )
    }

    func collectArtifacts(_ chat: JSONLSessionLayout.Chat) -> [Artifact] {
        var artifacts = [Artifact(url: chat.file, kind: .file, sizeBytes: FileSystem.size(of: chat.file), note: "Transcript")]
        for companion in flavor.companions {
            let url = layout.companion(chat, companion)
            guard FileSystem.exists(url) else { continue }
            artifacts.append(Artifact(url: url, kind: companion.isFolder ? .folder : .file, sizeBytes: FileSystem.size(of: url), note: companion.note))
        }
        return artifacts
    }

    private func files(of chat: JSONLSessionLayout.Chat) -> [URL] {
        collectArtifacts(chat).map(\.url)
    }

    // MARK: Guards

    private func locate(_ session: Session) throws -> JSONLSessionLayout.Chat {
        let file = session.transcriptURL.standardizedFileURL
        guard session.agent == kind, SafeID.isSafe(session.id), file.lastPathComponent == "\(session.id).jsonl", FileSystem.exists(file),
              FileSystem.relativePath(of: file, under: layout.sessions)?.split(separator: "/").count == 2,
              layout.header(of: file) != nil else {
            throw AdapterError.sessionNotFound(session.id)
        }
        return JSONLSessionLayout.Chat(id: session.id, file: file)
    }

    private func requireWritable() throws {
        switch layout.probe() {
        case .readOnly(let reason): throw AdapterError.readOnly(kind, reason: reason)
        case .notInstalled: throw AdapterError.notInstalled(kind)
        case .ready: break
        }
    }
}

extension JSONLSessionAdapter {
    public func footprint() async throws -> Footprint {
        guard FileSystem.isDirectory(root) else { throw AdapterError.notInstalled(kind) }
        var builder = FootprintBuilder(agent: kind, root: root)
        let count = layout.chats().count
        builder.add("Sessions", layout.sessions, .consequences,
                    "\(count) \(count == 1 ? "session" : "sessions"). Delete or archive them one by one in Sessions.", guidance: .manageInSessions)
        builder.add("Older sessions", flavor.legacyFolders.map { root.appendingPathComponent($0, isDirectory: true) }, reveal: root, .consequences,
                    "Sessions in the layout of older \(flavor.appName) versions. Domovy does not list them as sessions.")
        builder.add("Settings and sign-in", builder.unclaimedChildren(of: root), reveal: root, .keep,
                    "Sign-in, settings, skills and caches \(flavor.appName) needs. Domovy never removes them.")
        return builder.build()
    }
}
