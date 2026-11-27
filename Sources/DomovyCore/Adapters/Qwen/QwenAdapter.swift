import Foundation

/// Adapter for Qwen Code (`~/.qwen`, see `QwenLayout` for the source it was read from). One
/// session is `projects/<slug>/chats/<id>.jsonl` plus its sidecars, its subagent transcripts,
/// its file history and its resources. Qwen Code has no non-interactive delete or archive
/// (`qwen sessions` only lists; packages/cli/src/commands/sessions.ts#L13-L20), so Domovy moves
/// the files itself, with Qwen Code quit:
/// - delete moves every file of the session to the Trash or the quarantine;
/// - archive renames the transcript and its sidecars into `chats/archive/`, exactly as Qwen's own
///   archive does, so Qwen lists the session as archived; undo moves them back.
/// `session-organization.v1.json` (list groups and pins) is never edited.
public struct QwenAdapter: AgentAdapter {
    public let kind: AgentKind = .qwen
    public let root: URL

    let layout: QwenLayout
    let openHandles: any OpenHandleChecker
    let processes: any RunningProcessLister
    let probe: any ProcessProbe

    /// `qwen` (package.json bin) running as `node …/@qwen-code/qwen-code/…`.
    public static let processMatcher = ProcessMatcher(
        appName: "Qwen Code", names: [], exactNames: ["qwen"],
        quitAdvice: "Quit Qwen Code to change its sessions.", argumentMarkers: ["@qwen-code/qwen-code"]
    )

    /// - Parameters:
    ///   - qwenHome: the `.qwen` folder. Tests pass a copy of a fixture.
    ///   - runtime: Qwen's runtime folder (`QWEN_RUNTIME_DIR`); `qwenHome` by default.
    ///   - probe: whether a pid named in `sessions/<pid>.json` or a writer lock still runs.
    public init(
        qwenHome: URL,
        runtime: URL? = nil,
        openHandles: any OpenHandleChecker = LibprocOpenHandleChecker(),
        processes: any RunningProcessLister = LibprocProcessLister(),
        probe: any ProcessProbe = KillProcessProbe()
    ) {
        self.root = qwenHome.standardizedFileURL
        self.layout = QwenLayout(root: self.root, runtime: (runtime ?? qwenHome).standardizedFileURL)
        self.openHandles = openHandles
        self.processes = processes
        self.probe = probe
    }

    /// Convenience for a home directory: `<home>/.qwen`.
    public init(home: URL) {
        self.init(qwenHome: home.appendingPathComponent(".qwen", isDirectory: true), openHandles: LibprocOpenHandleChecker.shared)
    }

    public var scope: [URL] {
        layout.runtime == root ? [root] : [root, layout.runtime]
    }

    // MARK: AgentAdapter

    public func status() async -> AdapterStatus {
        layout.probe()
    }

    public func sessions() async throws -> [Session] {
        if case .notInstalled = layout.probe() { throw AdapterError.notInstalled(kind) }
        let markers = readMarkers()
        let chats = layout.chats()
        let groups = chats.map { collectArtifacts($0).map(\.url) }
        let holders = await openHandleHolders(of: groups, checker: openHandles)
        return zip(chats, holders).map { chat, holders in
            makeSession(chat, live: liveness(chat, markers: markers, holders: holders))
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

    /// One read of the registry and writer locks, one open-file question.
    public func liveChecks(for sessions: [Session]) async -> [Result<LiveCheckResult, any Error>] {
        let markers = readMarkers()
        return await FileSessions.liveChecks(
            for: sessions, checker: openHandles, locate: locate, files: { collectArtifacts($0).map(\.url) },
            liveness: { liveness($0, markers: markers, holders: $1) })
    }

    public func deletePlan(for session: Session, destination: Destination = .trash) async throws -> Plan {
        guard let planned = await deletePlans(for: [session], destination: destination).first else { throw AdapterError.sessionNotFound(session.id) }
        return try planned.result.get()
    }

    public func deletePlans(for sessions: [Session], destination: Destination) async -> [PlannedSession] {
        let writable = Result { try requireWritable() }
        let markers = readMarkers()
        let blocking = processes.blockingReasons([Self.processMatcher])
        return await FileSessions.plans(
            for: sessions, checker: openHandles, locate: locate, files: { collectArtifacts($0).map(\.url) },
            liveness: { liveness($0, markers: markers, holders: $1) },
            finish: { session, chat, live in
                try writable.get()
                let artifacts = collectArtifacts(chat)
                for artifact in artifacts where layout.isProtected(artifact.url) { throw AdapterError.protectedPathInPlan(artifact.url) }
                let moves = artifacts.map { FileMove(source: $0.url, kind: $0.kind, sizeBytes: $0.sizeBytes, note: $0.note) }
                var remarks = ["Qwen Code has no command to delete a session outside its own window, so Domovy moves the session's files itself while Qwen Code is quit."]
                remarks.append("If this session is in a group or pinned, that entry stays in the project's session-organization.v1.json. Qwen Code shows nothing for it once the session is gone.")
                if FileSystem.exists(chat.sidecar(".worktree.json")) {
                    remarks.append("This session had a git worktree. Domovy moves only Qwen Code's note about it; the worktree itself stays where it is.")
                }
                return Plan(agent: kind, sessionID: session.id, action: .delete, destination: destination, moves: moves, indexEdits: [],
                            remarks: remarks, mustNotBeRunning: [Self.processMatcher],
                            liveCheck: FileSessions.forPlan(live, blocking: blocking, app: "Qwen Code"), scope: scope)
            })
    }

    public func archivePlan(for session: Session) async throws -> Plan {
        guard let planned = await archivePlans(for: [session]).first else { throw AdapterError.sessionNotFound(session.id) }
        return try planned.result.get()
    }

    /// Qwen's own archive: the transcript and every sidecar but `.runtime.json` go into
    /// `chats/archive/` under the same names.
    public func archivePlans(for sessions: [Session]) async -> [PlannedSession] {
        let writable = Result { try requireWritable() }
        let markers = readMarkers()
        let blocking = processes.blockingReasons([Self.processMatcher])
        return await FileSessions.plans(
            for: sessions, checker: openHandles, locate: locate, files: { collectArtifacts($0).map(\.url) },
            liveness: { liveness($0, markers: markers, holders: $1) },
            finish: { session, chat, live in
                try writable.get()
                guard !chat.isArchived else {
                    return Plan(agent: kind, sessionID: session.id, action: .archive, destination: nil, moves: [], indexEdits: [],
                                remarks: ["This session is already in Qwen Code's archive (chats/archive/)."], liveCheck: live, scope: scope)
                }
                let archive = chat.folder.appendingPathComponent("archive", isDirectory: true)
                let files = [(chat.file, "Transcript")] + QwenLayout.sidecars.map { (chat.sidecar($0), "Sidecar (\($0.dropFirst()))") }
                var relocations: [FileRelocation] = []
                for (file, note) in files where FileSystem.exists(file) {
                    if layout.isProtected(file) { throw AdapterError.protectedPathInPlan(file) }
                    relocations.append(FileRelocation(source: file, target: archive.appendingPathComponent(file.lastPathComponent), kind: .file,
                                                      sizeBytes: FileSystem.size(of: file), note: note))
                }
                return Plan(agent: kind, sessionID: session.id, action: .archive, destination: nil, moves: [], indexEdits: [],
                            relocations: relocations,
                            remarks: ["Qwen Code archives a session the same way, so it lists this one as archived and can restore it."],
                            mustNotBeRunning: [Self.processMatcher],
                            liveCheck: FileSessions.forPlan(live, blocking: blocking, app: "Qwen Code"), scope: scope)
            })
    }

    public func transcript(of session: Session, limit: Int, masking findings: [SecretFinding]) async throws -> Transcript {
        let chat = try locate(session)
        return try FileSessions.readJSONLines(of: chat.file, maxMessages: limit, masking: findings) { record, index in
            Self.message(record, index: index)
        }
    }

    public func transcriptPage(of session: Session, limit: Int, before cursor: TranscriptCursor?, masking findings: [SecretFinding]) async throws -> Transcript {
        let chat = try locate(session)
        return try FileSessions.readJSONLinesPage(of: chat.file, limit: limit, before: cursor, masking: findings) { record, index in
            Self.message(record, index: index)
        }
    }

    // MARK: Sessions

    private func makeSession(_ chat: QwenLayout.Chat, live: LiveCheckResult) -> Session {
        let head = FileSessions.records(in: chat.file)
        let size = collectArtifacts(chat).reduce(Int64(0)) { $0 + $1.sizeBytes }
        return Session(
            id: chat.id,
            agent: kind,
            title: title(of: chat, head: head),
            projectPath: head.lazy.compactMap { $0["cwd"] as? String }.first { $0.hasPrefix("/") },
            lastActive: FileSystem.modificationDate(of: chat.file) ?? .distantPast,
            sizeBytes: size,
            status: live.isLive ? .live : chat.isArchived ? .archived : .idle,
            expiresAt: nil,
            transcriptURL: chat.file,
            isArchived: chat.isArchived
        )
    }

    /// The list label (`.title.json`, session-title-sidecar.ts#L109-L125), else the newest
    /// `custom_title` record (chatRecordingService.ts#L2305-L2318), else the first prompt.
    private func title(of chat: QwenLayout.Chat, head: [[String: Any]]) -> String? {
        if let label = FileSessions.object(chat.sidecar(".title.json"))?["displayName"] as? String, let title = FileSessions.title(label) {
            return title
        }
        let custom = (head + FileSessions.tailRecords(in: chat.file)).last { $0["subtype"] as? String == "custom_title" }
        if let text = (custom?["systemPayload"] as? [String: Any])?["customTitle"] as? String, let title = FileSessions.title(text) {
            return title
        }
        let prompt = head.first { $0["type"] as? String == "user" && $0["subtype"] == nil }
        return FileSessions.title(FileSessions.text(of: (prompt?["message"] as? [String: Any])?["parts"]))
    }

    /// `user` records without a subtype are prompts; `assistant` records carry the model's parts
    /// (`{role: model, parts: [{text} | {functionCall: {name}}]}`, chatRecordingService.ts#L2808-L2826, #L3275-L3306).
    static func message(_ record: [String: Any], index: Int) -> TranscriptMessage? {
        let role: TranscriptMessage.Role
        switch record["type"] as? String {
        case "user" where record["subtype"] == nil: role = .user
        case "assistant": role = .assistant
        default: return nil
        }
        let parts = (record["message"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        var blocks: [TranscriptMessage.Block] = []
        for part in parts {
            if part["thought"] as? Bool == true { continue }
            if let text = (part["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                blocks.append(.text(text))
            } else if let call = part["functionCall"] as? [String: Any] {
                blocks.append(.toolCall((call["name"] as? String) ?? "Tool"))
            }
        }
        guard !blocks.isEmpty else { return nil }
        return TranscriptMessage(id: (record["uuid"] as? String) ?? "q\(index)", role: role,
                                 timestamp: FileSessions.date(record["timestamp"] as? String), blocks: blocks)
    }

    // MARK: Artifacts

    func collectArtifacts(_ chat: QwenLayout.Chat) -> [Artifact] {
        var artifacts: [Artifact] = []
        func add(_ url: URL, _ kind: Artifact.Kind, _ note: String) {
            guard FileSystem.exists(url), !layout.isProtected(url) else { return }
            artifacts.append(Artifact(url: url, kind: kind, sizeBytes: FileSystem.size(of: url), note: note))
        }
        add(chat.file, .file, "Transcript")
        for suffix in QwenLayout.sidecars + [QwenLayout.runtimeSidecar] {
            add(chat.sidecar(suffix), .file, "Sidecar (\(suffix.dropFirst()))")
        }
        // An archived session's runtime record stays in chats/ (sessionService.ts#L2198-L2310).
        if chat.isArchived {
            add(chat.project.appendingPathComponent("chats/\(chat.id)\(QwenLayout.runtimeSidecar)"), .file, "Sidecar (runtime.json)")
        }
        add(chat.project.appendingPathComponent("subagents/\(chat.id)", isDirectory: true), .folder, "Subagent transcripts")
        add(layout.fileHistory.appendingPathComponent(chat.id, isDirectory: true), .folder, "File history (undo of edits)")
        add(layout.resources.appendingPathComponent(chat.id, isDirectory: true), .folder, "Session resources")
        return artifacts
    }

    // MARK: Liveness

    /// Qwen's own liveness files, read once per call.
    struct Markers: Sendable {
        /// Session id (lowercased) to the pids `sessions/*.json` name for it.
        let registry: [String: [Int32?]]
        /// Writer lock file names (`<id>.lock`) to their pid, `nil` when unreadable.
        let locks: [String: Int32?]
    }

    func readMarkers() -> Markers {
        var registry: [String: [Int32?]] = [:]
        for file in FileSystem.children(of: layout.registry) where file.pathExtension == "json" {
            guard let object = FileSessions.object(file), let id = object["sessionId"] as? String else { continue }
            let pid = (object["pid"] as? NSNumber).map { Int32(truncating: $0) }
                ?? Int32(file.deletingPathExtension().lastPathComponent.split(separator: "-").first ?? "")
            registry[id.lowercased(), default: []].append(pid)
        }
        var locks: [String: Int32?] = [:]
        for file in FileSystem.children(of: layout.writerLocks) where file.pathExtension == "lock" {
            locks[file.lastPathComponent.lowercased()] = (FileSessions.object(file)?["pid"] as? NSNumber).map { Int32(truncating: $0) }
        }
        return Markers(registry: registry, locks: locks)
    }

    private func liveness(_ chat: QwenLayout.Chat, markers: Markers, holders: [OpenHandleHolder]?) -> LiveCheckResult {
        var reasons: [String] = []
        for pid in markers.registry[chat.id.lowercased()] ?? [] where pid.map(probe.isRunning) ?? true {
            reasons.append("Qwen Code reports this session as running\(pid.map { " (pid \($0))" } ?? ""). Quit that Qwen Code session first.")
        }
        // A lock whose pid is gone is left by a crash; one Domovy cannot read counts as held.
        if let pid = markers.locks["\(chat.id.lowercased()).lock"], pid.map(probe.isRunning) ?? true {
            reasons.append("Qwen Code holds this session's writer lock\(pid.map { " (pid \($0))" } ?? ""). Close it in Qwen Code first.")
        }
        return FileSessions.liveness(markers: reasons, holders: holders, signals: ["sessions/*.json", "session-writer-locks"])
    }

    // MARK: Guards

    private func locate(_ session: Session) throws -> QwenLayout.Chat {
        let file = session.transcriptURL.standardizedFileURL
        guard session.agent == kind, SafeID.isSafe(session.id), file.lastPathComponent == "\(session.id).jsonl",
              FileSystem.exists(file), FileSystem.relativePath(of: file, under: layout.projects) != nil else {
            throw AdapterError.sessionNotFound(session.id)
        }
        let folder = file.deletingLastPathComponent()
        let archived = folder.lastPathComponent == "archive"
        let chats = archived ? folder.deletingLastPathComponent() : folder
        guard chats.lastPathComponent == "chats" else { throw AdapterError.sessionNotFound(session.id) }
        return QwenLayout.Chat(id: session.id, file: file, project: chats.deletingLastPathComponent(), isArchived: archived)
    }

    private func requireWritable() throws {
        switch layout.probe() {
        case .readOnly(let reason): throw AdapterError.readOnly(kind, reason: reason)
        case .notInstalled: throw AdapterError.notInstalled(kind)
        case .ready: break
        }
    }
}

extension QwenAdapter {
    /// Read-only breakdown of `~/.qwen`. Sizes come from file metadata; nothing is opened.
    public func footprint() async throws -> Footprint {
        guard FileSystem.isDirectory(root) else { throw AdapterError.notInstalled(kind) }
        var builder = FootprintBuilder(agent: kind, root: root)
        let settings = QwenLayout.protectedEntries.sorted().map { root.appendingPathComponent($0) }
        builder.add("Settings and sign-in", settings, reveal: root, .keep, "Qwen Code needs these to run. Domovy never removes them.")
        let count = layout.chats().count
        builder.add("Sessions", layout.projects, .consequences,
                    "\(count) \(count == 1 ? "session" : "sessions") with their sidecars and subagent transcripts. Delete or archive them one by one in Sessions.",
                    guidance: .manageInSessions)
        builder.add("File history", layout.fileHistory, .consequences, "Copies of files before Qwen Code edited them, for undo. They go with each session in Sessions.",
                    guidance: .manageInSessions)
        builder.add("Older chats", layout.legacyChats(), reveal: layout.tmp, .consequences,
                    "Chats in the layout of older Qwen Code versions (tmp/<hash>/chats/). Qwen Code 0.28 no longer reads them; Domovy does not list them as sessions.")
        builder.add("Tool results and checkpoints", layout.tmp, .consequences,
                    "Large tool outputs and checkpoints per project. Qwen Code clears tool results older than a day itself.")
        builder.add("Other", builder.unclaimedChildren(of: root), reveal: root, .keep, "Caches and state Domovy does not manage yet. Left alone.")
        return builder.build()
    }
}
