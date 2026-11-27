import Foundation

/// Continue's sessions, read from continuedev/continue@5522c6f4 (docs/research/agent_storage_formats.md,
/// Q9; not verified on a real install). Permalink base:
/// https://github.com/continuedev/continue/blob/5522c6f44ca0ac3528b37244818fbfa39b5af470/
///
/// - Global folder `~/.continue` (`CONTINUE_GLOBAL_DIR`; core/util/paths.ts#L27-L36). Sessions are
///   `sessions/<id>.json` `{sessionId, title, workspaceDirectory, history: [{message: {role, content}}], …}`
///   (core/util/paths.ts#L78-L112, core/index.d.ts#L279-L354).
/// - `sessions/sessions.json` lists them: `[{sessionId, title, dateCreated (ms as text), workspaceDirectory,
///   messageCount}]` (core/index.d.ts#L292-L298, core/util/history.ts#L171).
/// - Continue's delete unlinks the file and rewrites the list, without a lock (core/util/history.ts#L60-L85);
///   every save rewrites the whole list (#L111-L192), from VS Code, JetBrains and the `cn` CLI alike
///   (extensions/cli/src/session.ts#L35-L59). So Domovy edits the list only while none of them runs.
struct ContinueLayout: Sendable {
    let root: URL

    var sessions: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    var list: URL { sessions.appendingPathComponent("sessions.json") }

    func file(of id: String) -> URL { sessions.appendingPathComponent("\(id).json") }

    /// Settings, rules, MCP servers and indexes Continue needs (core/util/paths.ts#L58-L125, #L236-L339, #L378-L468).
    static let protectedEntries: Set<String> = [
        "config.yaml", "config.json", "config.ts", ".continuerc.json", ".env", "sharedConfig.json", ".continueignore",
        "mcpServers", "assistants", "agents", "configs", "rules", "prompts", "index", ".local", ".staging",
    ]

    func isProtected(_ url: URL) -> Bool {
        guard let relative = FileSystem.relativePath(of: url, under: root) else { return false }
        let parts = relative.split(separator: "/").map(String.init)
        guard let first = parts.first else { return true }
        if first == "sessions" { return parts.count < 2 || parts[1] == "sessions.json" }
        return Self.protectedEntries.contains(first)
    }

    struct Entry: Sendable {
        let title: String?
        let created: Date?
        let workspace: String?
    }

    /// The list as Continue reads it; entries of the old format (`session_id`) are skipped as
    /// Continue skips them (core/util/history.ts#L33-L39). `nil` when it is not a JSON list.
    func entries() -> [String: Entry]? {
        guard FileSystem.exists(list) else { return [:] }
        guard let data = try? Data(contentsOf: list) else { return nil }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        var result: [String: Entry] = [:]
        for case let item as [String: Any] in items {
            guard let id = item["sessionId"] as? String else { continue }
            result[id] = Entry(title: FileSessions.title(item["title"] as? String), created: FileSessions.epoch(item["dateCreated"]),
                               workspace: path(item["workspaceDirectory"] as? String))
        }
        return result
    }

    func sessionFiles() -> [URL] {
        FileSystem.children(of: sessions).filter { file in
            file.pathExtension == "json" && file.lastPathComponent != "sessions.json" && SafeID.isSafe(file.deletingPathExtension().lastPathComponent)
        }.map(\.standardizedFileURL)
    }

    /// `workspaceDirectory` is a folder URI (`file:///…`) or a path.
    func path(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        if let url = URL(string: text), url.isFileURL { return url.path }
        return text.hasPrefix("/") ? text : nil
    }
}

/// Adapter for Continue. Delete moves `sessions/<id>.json` to the Trash or the quarantine and cuts the
/// session's entry out of `sessions.json` (every other byte stays, a copy is kept first), only while
/// no editor or `cn` that could run Continue is open. Archive compresses the session file in place.
public struct ContinueAdapter: AgentAdapter {
    public let kind: AgentKind = .continueDev
    public let root: URL

    let layout: ContinueLayout
    let openHandles: any OpenHandleChecker
    let processes: any RunningProcessLister

    /// The `cn` CLI (`@continuedev/cli`, extensions/cli/package.json) and the JetBrains plugin's
    /// `continue-binary` (extensions/intellij/…/utils/Paths.kt#L44).
    public static let cliMatcher = ProcessMatcher(appName: "Continue", names: ["cn", "continue-binary"],
                                                  quitAdvice: "Quit the Continue CLI (cn) and JetBrains IDEs that run Continue first.",
                                                  argumentMarkers: ["@continuedev/cli"])

    /// Apps whose Continue rewrites `sessions.json`: the CLI, the JetBrains core, and VS Code with its forks.
    public static var matchers: [ProcessMatcher] {
        [cliMatcher] + VSCodeFlavor.all.map(\.matcher) + [CursorLayout.appMatcher]
    }

    public static let acknowledgement = "Undo puts Continue's session list (sessions.json) back only while Continue has not changed it since. Once Continue saves a session, the list stays as it is; the session file still comes back."

    public init(continueHome: URL, openHandles: any OpenHandleChecker = LibprocOpenHandleChecker(),
                processes: any RunningProcessLister = LibprocProcessLister()) {
        self.root = continueHome.standardizedFileURL
        self.layout = ContinueLayout(root: self.root)
        self.openHandles = openHandles
        self.processes = processes
    }

    public init(home: URL) {
        self.init(continueHome: home.appendingPathComponent(".continue", isDirectory: true), openHandles: LibprocOpenHandleChecker.shared)
    }

    // MARK: AgentAdapter

    public func status() async -> AdapterStatus {
        guard FileSystem.isDirectory(layout.sessions) else { return .notInstalled }
        guard layout.entries() != nil else {
            return .readOnly(reason: "Continue's sessions.json is not the JSON list Domovy knows, so it only lists what it can read.")
        }
        for file in layout.sessionFiles().prefix(50) where FileSystem.size(of: file) < 16 * 1024 * 1024 {
            guard let object = FileSessions.object(file), object["sessionId"] as? String == file.deletingPathExtension().lastPathComponent,
                  object["history"] is [Any] else {
                return .readOnly(reason: "A Continue session file (\(file.lastPathComponent)) does not have the layout Domovy knows (sessionId and history), so it only lists what it can read.")
            }
        }
        return .ready
    }

    public func sessions() async throws -> [Session] {
        guard FileSystem.isDirectory(layout.sessions) else { throw AdapterError.notInstalled(kind) }
        let entries = layout.entries() ?? [:]
        let files = layout.sessionFiles()
        let holders = await openHandleHolders(of: files.map { [$0] }, checker: openHandles)
        return zip(files, holders).map { file, holders in
            let id = file.deletingPathExtension().lastPathComponent
            let entry = entries[id]
            let header = entry == nil ? FileSessions.object(file) : nil
            let archived = APFSCompression.isCompressed(file)
            let live = FileSessions.liveness(markers: [], holders: holders, signals: [])
            return Session(id: id, agent: kind,
                           title: entry?.title ?? FileSessions.title(header?["title"] as? String),
                           projectPath: entry?.workspace ?? layout.path(header?["workspaceDirectory"] as? String),
                           lastActive: FileSystem.modificationDate(of: file) ?? entry?.created ?? .distantPast,
                           sizeBytes: FileSystem.size(of: file), status: live.isLive ? .live : archived ? .archived : .idle, expiresAt: nil,
                           transcriptURL: file, isArchived: archived)
        }
        .sorted { $0.lastActive > $1.lastActive }
    }

    public func artifacts(of session: Session) async throws -> [Artifact] {
        let file = try locate(session)
        var artifacts = [Artifact(url: file, kind: .file, sizeBytes: FileSystem.size(of: file), note: "Session")]
        if layout.entries()?[session.id] != nil {
            artifacts.append(Artifact(url: layout.list, kind: .indexEntry, sizeBytes: 0, note: "Entry in Continue's session list (sessions.json)"))
        }
        return artifacts
    }

    public func liveCheck(_ session: Session) async throws -> LiveCheckResult {
        guard let result = await liveChecks(for: [session]).first else { throw AdapterError.sessionNotFound(session.id) }
        return try result.get()
    }

    public func liveChecks(for sessions: [Session]) async -> [Result<LiveCheckResult, any Error>] {
        await FileSessions.liveChecks(for: sessions, checker: openHandles, locate: locate, files: { [$0] },
                                      liveness: { FileSessions.liveness(markers: [], holders: $1, signals: []) })
    }

    public func deletePlan(for session: Session, destination: Destination = .trash) async throws -> Plan {
        guard let planned = await deletePlans(for: [session], destination: destination).first else { throw AdapterError.sessionNotFound(session.id) }
        return try planned.result.get()
    }

    /// One read of the list; each plan cuts its own entry, so a batch edits the list once per session.
    public func deletePlans(for sessions: [Session], destination: Destination) async -> [PlannedSession] {
        let state = await status()
        let entries = layout.entries() ?? [:]
        let blocking = processes.blockingReasons(Self.matchers)
        return await FileSessions.plans(
            for: sessions, checker: openHandles, locate: locate, files: { [$0, layout.list] },
            liveness: { FileSessions.liveness(markers: [], holders: $1, signals: []) },
            finish: { session, file, live in
                if case .readOnly(let reason) = state { throw AdapterError.readOnly(kind, reason: reason) }
                if layout.isProtected(file) { throw AdapterError.protectedPathInPlan(file) }
                let move = FileMove(source: file, kind: .file, sizeBytes: FileSystem.size(of: file), note: "Session")
                var removals: [JSONMemberRemoval] = []
                if entries[session.id] != nil {
                    removals.append(JSONMemberRemoval(file: layout.list, field: "", key: session.id, sizeBytes: 0,
                                                      note: "Its entry in Continue's session list", idField: "sessionId"))
                }
                let remarks = ["Continue deletes a session by removing its file and its entry in sessions.json. Domovy does the same while Continue is not running anywhere, keeping a copy of sessions.json first."]
                return Plan(agent: kind, sessionID: session.id, action: .delete, destination: destination, moves: [move], indexEdits: [],
                            jsonRemovals: removals, remarks: remarks, acknowledgement: removals.isEmpty ? nil : Self.acknowledgement,
                            mustNotBeRunning: Self.matchers,
                            liveCheck: FileSessions.forPlan(live, blocking: blocking, app: "Continue"), scope: scope)
            })
    }

    public func archivePlan(for session: Session) async throws -> Plan {
        let file = try locate(session)
        if case .readOnly(let reason) = await status() { throw AdapterError.readOnly(kind, reason: reason) }
        let compressions = try FileSessions.compressions(of: [Artifact(url: file, kind: .file, sizeBytes: 0, note: "Session")], isProtected: layout.isProtected)
        return Plan(agent: kind, sessionID: session.id, action: .archive, destination: nil, moves: [], indexEdits: [], compressions: compressions,
                    liveCheck: try await liveCheck(session), scope: scope)
    }

    /// `history[].message` `{role, content}`, content a string or `[{type: text, text}]`
    /// (core/index.d.ts#L335-L354, core/util/messageContent.ts#L9-L32). Masked before it is shown.
    public func transcript(of session: Session, limit: Int, masking findings: [SecretFinding]) async throws -> Transcript {
        let file = try locate(session)
        guard FileSystem.size(of: file) <= 16 * 1024 * 1024, let object = FileSessions.object(file) else { return .empty }
        let masker = TranscriptMask.TextMasker()
        var messages: [TranscriptMessage] = []
        for (index, item) in (object["history"] as? [[String: Any]] ?? []).enumerated() {
            guard let message = item["message"] as? [String: Any] else { continue }
            let role: TranscriptMessage.Role
            switch message["role"] as? String {
            case "user": role = .user
            case "assistant": role = .assistant
            default: continue
            }
            var blocks: [TranscriptMessage.Block] = []
            if let text = FileSessions.text(of: message["content"]) { blocks.append(.text(masker.mask(text))) }
            for case let call as [String: Any] in message["toolCalls"] as? [Any] ?? [] {
                blocks.append(.toolCall(((call["function"] as? [String: Any])?["name"] as? String) ?? "Tool"))
            }
            guard !blocks.isEmpty else { continue }
            if messages.count == limit { return Transcript(messages: messages, isTruncated: true) }
            messages.append(TranscriptMessage(id: "c\(index)", role: role, timestamp: nil, blocks: blocks))
        }
        return Transcript(messages: messages, isTruncated: false)
    }

    private func locate(_ session: Session) throws -> URL {
        let file = layout.file(of: session.id).standardizedFileURL
        guard session.agent == kind, SafeID.isSafe(session.id), session.id != "sessions",
              session.transcriptURL.standardizedFileURL == file, FileSystem.exists(file) else {
            throw AdapterError.sessionNotFound(session.id)
        }
        return file
    }
}

extension ContinueAdapter {
    public func footprint() async throws -> Footprint {
        guard FileSystem.isDirectory(root) else { throw AdapterError.notInstalled(kind) }
        var builder = FootprintBuilder(agent: kind, root: root)
        builder.add("Settings, rules and indexes", ContinueLayout.protectedEntries.sorted().map { root.appendingPathComponent($0) }, reveal: root, .keep,
                    "Continue needs these to run. Domovy never removes them.")
        let count = layout.sessionFiles().count
        builder.add("Sessions", layout.sessions, .consequences,
                    "\(count) \(count == 1 ? "session" : "sessions"). Delete or archive them one by one in Sessions.", guidance: .manageInSessions)
        builder.add("Usage data", root.appendingPathComponent("dev_data", isDirectory: true), .consequences,
                    "Continue's local record of completions and chats, for its own statistics.")
        builder.add("Logs", root.appendingPathComponent("logs", isDirectory: true), .safe, "Diagnostic logs. Remove them while Continue is not running.")
        builder.add("Other", builder.unclaimedChildren(of: root), reveal: root, .keep, "Caches and state Domovy does not manage yet. Left alone.")
        return builder.build()
    }
}
