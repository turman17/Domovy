import Foundation

/// Adapter for Gemini CLI (`~/.gemini`). One session is one chat file plus what Gemini CLI
/// keys by its session id: subagent chats, the activity log, tool outputs and the session
/// folder (plans, task trackers). Delete moves those files to the Trash or the quarantine.
/// Domovy never runs `gemini --delete-session`: Gemini CLI runs its own retention sweep first,
/// which deletes other chats for good, and it deletes every chat whose name ends the same way.
/// Empty chats that share one session id (Gemini CLI's a2a server) are one row.
public struct GeminiAdapter: AgentAdapter {
    public let kind: AgentKind = .gemini
    public let root: URL
    /// Sessions whose retention deadline is this close are reported as `.expiring`.
    public let expiringWindowDays: Int

    let layout: GeminiLayout
    let openHandles: any OpenHandleChecker
    let processes: any RunningProcessLister
    let now: @Sendable () -> Date

    /// Gemini CLI runs as `node …/@google/gemini-cli/…` (verified for the Homebrew install) or
    /// as a `gemini` binary (assumed). The case-sensitive name keeps Google's `Gemini` chat app out.
    public static let processMatcher = ProcessMatcher(
        appName: "Gemini CLI", names: [], exactNames: ["gemini"],
        quitAdvice: "Quit Gemini CLI to change its chats.", argumentMarkers: ["@google/gemini-cli"]
    )

    /// - Parameters:
    ///   - geminiHome: the `.gemini` folder. Tests pass a copy of a fixture.
    ///   - openHandles: open-file-handle check; libproc by default.
    ///   - processes: running-Gemini-CLI check before a delete.
    public init(
        geminiHome: URL,
        expiringWindowDays: Int = 7,
        openHandles: any OpenHandleChecker = LibprocOpenHandleChecker(),
        processes: any RunningProcessLister = LibprocProcessLister(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.root = geminiHome.standardizedFileURL
        self.layout = GeminiLayout(root: self.root)
        self.expiringWindowDays = expiringWindowDays
        self.openHandles = openHandles
        self.processes = processes
        self.now = now
    }

    /// Convenience for a home directory: `<home>/.gemini`.
    public init(home: URL) {
        self.init(geminiHome: home.appendingPathComponent(".gemini", isDirectory: true))
    }

    // MARK: AgentAdapter

    public func status() async -> AdapterStatus {
        layout.probe()
    }

    public func sessions() async throws -> [Session] {
        if case .notInstalled = layout.probe() { throw AdapterError.notInstalled(kind) }
        let settings = GeminiSettings.load(from: layout.settings)
        let registry = layout.registry()
        let projects = layout.projectFolders().map { GeminiProject(folder: $0, registry: registry) }
        let groups = GeminiChatGroup.groups(in: projects)
        let grouped = Set(groups.flatMap { $0.members.map(\.chat.file) })
        let ids = Self.sessionIDs(projects.flatMap(\.chats).filter { !grouped.contains($0.file) })
        var result: [Session] = []
        for project in projects {
            let due = project.dueForSweep(settings)
            for chat in project.chats where !grouped.contains(chat.file) {
                result.append(await makeSession(chat, id: ids[chat.file] ?? chat.file.lastPathComponent, project: project, settings: settings, due: due[chat.file]))
            }
        }
        for group in groups { result.append(await makeSession(group, settings: settings)) }
        return result.sorted { $0.lastActive > $1.lastActive }
    }

    public func artifacts(of session: Session) async throws -> [Artifact] {
        switch try locate(session) {
        case .chat(let project, let chat): collectArtifacts(chat, in: project)
        case .group(let group): collectArtifacts(group)
        }
    }

    public func liveCheck(_ session: Session) async throws -> LiveCheckResult {
        await liveness(try artifacts(of: session).filter { $0.kind != .indexEntry }.map(\.url))
    }

    /// Moves the chat and what Gemini CLI keys by its id (or every chat of a group).
    public func deletePlan(for session: Session, destination: Destination = .trash) async throws -> Plan {
        let target = try locate(session)
        try requireWritable()
        let files = try await artifacts(of: session).filter { $0.kind != .indexEntry }
        for artifact in files where layout.isProtected(artifact.url) { throw AdapterError.protectedPathInPlan(artifact.url) }
        let live = await planCheck(files.map(\.url))
        let remarks: [String]
        switch target {
        case .chat(let project, let chat): remarks = sharedRemarks(chat, in: project)
        case .group(let group): remarks = groupRemarks(group)
        }
        let moves = files.map { FileMove(source: $0.url, kind: $0.kind, sizeBytes: $0.sizeBytes, note: $0.note) }
        return Plan(agent: kind, sessionID: session.id, action: .delete, destination: destination, moves: moves, indexEdits: [],
                    remarks: remarks, mustNotBeRunning: [Self.processMatcher], liveCheck: live, scope: self.scope)
    }

    /// Compresses the chat and its bulky companions in place with APFS transparent compression.
    /// Gemini CLI reads them unchanged and can resume; modification times stay as they were.
    public func archivePlan(for session: Session) async throws -> Plan {
        _ = try locate(session)
        try requireWritable()
        var compressions: [FileCompression] = []
        for artifact in try await artifacts(of: session) where Self.archivedNotes.contains(artifact.note) {
            for file in APFSCompression.regularFiles(at: artifact.url) {
                if layout.isProtected(file) { throw AdapterError.protectedPathInPlan(file) }
                guard !APFSCompression.isCompressed(file), FileSystem.size(of: file) > APFSCompression.minimumUsefulSize else { continue }
                compressions.append(FileCompression(
                    file: file,
                    sizeBytes: APFSCompression.allocatedBytes(of: file),
                    estimatedBytes: APFSCompression.estimatedCompressedBytes(of: file),
                    modificationTime: FileSystem.modificationTime(of: file),
                    note: artifact.note
                ))
            }
        }
        let live = await liveness(compressions.map(\.file))
        return Plan(agent: kind, sessionID: session.id, action: .archive, destination: nil, moves: [], indexEdits: [],
                    compressions: compressions, liveCheck: live, scope: self.scope)
    }

    /// A group of empty chats has nothing to show.
    public func transcript(of session: Session, limit: Int, masking findings: [SecretFinding]) async throws -> Transcript {
        guard case .chat(_, let chat) = try locate(session) else { return .empty }
        return try GeminiChat.readTranscript(of: chat.file, maxMessages: limit, masking: findings)
    }

    // MARK: Sessions

    /// The session id where it is unique; Gemini CLI's a2a server reuses one id for many
    /// chats, so those get the chat's timestamp appended (and the project, if still not unique).
    static func sessionIDs(_ chats: [GeminiProject.Chat]) -> [URL: String] {
        func base(_ chat: GeminiProject.Chat) -> String {
            (chat.header.sessionID ?? chat.file.deletingPathExtension().lastPathComponent).lowercased()
        }
        let counts = Dictionary(grouping: chats, by: base).mapValues(\.count)
        var result: [URL: String] = [:]
        var used: [String: Int] = [:]
        for chat in chats.sorted(by: { $0.file.path < $1.file.path }) {
            var id = base(chat)
            if counts[id, default: 0] > 1 {
                id += "-" + (GeminiLayout.stamp(ofChatNamed: chat.file.lastPathComponent) ?? chat.file.lastPathComponent).lowercased()
            }
            if let n = used[id] {
                used[id] = n + 1
                id += "-\(chat.file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent.lowercased())"
            } else {
                used[id] = 1
            }
            result[chat.file] = id
        }
        return result
    }

    private func makeSession(_ chat: GeminiProject.Chat, id: String, project: GeminiProject, settings: GeminiSettings, due: String?) async -> Session {
        let artifacts = collectArtifacts(chat, in: project)
        let size = artifacts.filter { $0.kind != .indexEntry }.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let live = await liveness(artifacts.filter { $0.kind != .indexEntry }.map(\.url))
        let archived = APFSCompression.isCompressed(chat.file)
        let expiresAt: Date? = due != nil ? chat.lastActive : settings.maxAge.map { chat.lastActive.addingTimeInterval($0) }
        let status: Session.Status
        if live.isLive {
            status = .live
        } else if let expiresAt, expiresAt.timeIntervalSince(now()) <= TimeInterval(expiringWindowDays) * 86_400 {
            status = .expiring
        } else if archived {
            status = .archived
        } else {
            status = .idle
        }
        return Session(
            id: id,
            agent: kind,
            title: chat.header.title ?? (chat.header.hasMessages ? nil : "Empty chat (no messages)"),
            projectPath: project.path,
            lastActive: chat.lastActive,
            sizeBytes: size,
            status: status,
            expiresAt: expiresAt,
            transcriptURL: chat.file,
            isArchived: archived,
            retentionNote: due
        )
    }

    /// One row for a group of empty chats. Gemini CLI removes chats without messages at its next
    /// start in their project, so the row is expiring unless the sweep is off.
    private func makeSession(_ group: GeminiChatGroup, settings: GeminiSettings) async -> Session {
        let artifacts = collectArtifacts(group)
        let live = await liveness(artifacts.map(\.url))
        let lastActive = group.newest?.chat.lastActive ?? .distantPast
        let swept = settings.isEnabled
        return Session(
            id: group.id,
            agent: kind,
            title: group.title,
            projectPath: group.projectPath,
            lastActive: lastActive,
            sizeBytes: artifacts.reduce(Int64(0)) { $0 + $1.sizeBytes },
            status: live.isLive ? .live : swept ? .expiring : .idle,
            expiresAt: swept ? lastActive : nil,
            transcriptURL: group.newest?.chat.file ?? layout.tmp,
            retentionNote: swept ? "Gemini CLI removes chats without messages the next time it starts in their project." : nil,
            memberCount: group.members.count
        )
    }

    // MARK: Artifacts

    private static let archivedNotes: Set<String> = [GeminiNote.chat, GeminiNote.subagents, GeminiNote.toolOutputs]

    /// The chat file and, when the session id is the chat's own, everything Gemini CLI keys by it.
    func collectArtifacts(_ chat: GeminiProject.Chat, in project: GeminiProject) -> [Artifact] {
        var artifacts: [Artifact] = []
        func add(_ url: URL, _ kind: Artifact.Kind, _ note: String) {
            guard FileSystem.exists(url), !layout.isProtected(url) else { return }
            artifacts.append(Artifact(url: url, kind: kind, sizeBytes: FileSystem.size(of: url), note: note))
        }
        add(chat.file, .file, GeminiNote.chat)
        guard let id = project.ownedID(of: chat) else { return artifacts }
        let folder = project.folder
        add(folder.appendingPathComponent("chats/\(id)", isDirectory: true), .folder, GeminiNote.subagents)
        add(folder.appendingPathComponent("logs/session-\(id).jsonl"), .file, "Activity log")
        add(folder.appendingPathComponent("tool-outputs/session-\(id)", isDirectory: true), .folder, GeminiNote.toolOutputs)
        add(folder.appendingPathComponent(id, isDirectory: true), .folder, "Plans and task trackers")
        if let prompts = project.promptCount(for: id), prompts > 0 {
            artifacts.append(Artifact(url: project.promptLog, kind: .indexEntry, sizeBytes: 0,
                                      note: "\(prompts) typed \(prompts == 1 ? "prompt" : "prompts") in logs.json; the file stays as it is"))
        }
        return artifacts
    }

    /// Every chat file of a group. The activity log and folder of the shared id are not theirs.
    func collectArtifacts(_ group: GeminiChatGroup) -> [Artifact] {
        group.members.compactMap { member in
            let url = member.chat.file
            guard FileSystem.exists(url), !layout.isProtected(url) else { return nil }
            return Artifact(url: url, kind: .file, sizeBytes: FileSystem.size(of: url), note: GeminiNote.emptyChat)
        }
    }

    private func groupRemarks(_ group: GeminiChatGroup) -> [String] {
        ["All \(group.members.count) chats share the session id \(group.sessionID) and hold no messages. Gemini CLI removes such chats itself the next time it starts in their project.",
         "The activity log and session folder of that id are shared with any other chat using it, so they stay."]
    }

    /// What stays behind, said plainly.
    private func sharedRemarks(_ chat: GeminiProject.Chat, in project: GeminiProject) -> [String] {
        var remarks: [String] = []
        if let id = chat.header.sessionID, project.ownedID(of: chat) == nil {
            let others = project.chats.filter { $0.header.sessionID == id }.count - 1
            remarks.append("\(others) other \(others == 1 ? "chat uses" : "chats use") the same session id, so its activity log and session folder are shared and stay.")
        }
        if let id = project.ownedID(of: chat), let prompts = project.promptCount(for: id), prompts > 0 {
            remarks.append("\(prompts) typed \(prompts == 1 ? "prompt stays" : "prompts stay") in this project's logs.json. Domovy does not edit that file, and Gemini CLI keeps them too.")
        }
        return remarks
    }

    // MARK: Liveness

    /// Live when a process holds one of the session's files open. Gemini CLI appends to its chat
    /// without keeping it open, so delete also requires Gemini CLI to be quit.
    private func liveness(_ urls: [URL]) async -> LiveCheckResult {
        var reasons: [String] = []
        let status: LiveCheckResult.OpenHandleStatus
        if let holders = await openHandles.holders(of: urls) {
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

    private func planCheck(_ urls: [URL]) async -> LiveCheckResult {
        let base = await liveness(urls)
        let blocking = processes.blockingReasons([Self.processMatcher])
        return LiveCheckResult(isLive: base.isLive || !blocking.isEmpty, reasons: base.reasons + blocking,
                               checkedSignals: base.checkedSignals + ["Gemini CLI processes"], openHandles: base.openHandles)
    }

    // MARK: Guards

    enum Target {
        case chat(GeminiProject, GeminiProject.Chat)
        case group(GeminiChatGroup)
    }

    private func locate(_ session: Session) throws -> Target {
        guard session.agent == kind else { throw AdapterError.sessionNotFound(session.id) }
        if session.memberCount > 1 || session.id.hasSuffix(GeminiChatGroup.idSuffix) {
            let registry = layout.registry()
            let projects = layout.projectFolders().map { GeminiProject(folder: $0, registry: registry) }
            if let group = GeminiChatGroup.groups(in: projects).first(where: { $0.id == session.id }) { return .group(group) }
            if session.memberCount > 1 { throw AdapterError.sessionNotFound(session.id) }
        }
        let file = session.transcriptURL.standardizedFileURL
        let folder = file.deletingLastPathComponent().deletingLastPathComponent()
        guard FileSystem.relativePath(of: file, under: layout.tmp) != nil, FileSystem.exists(file) else {
            throw AdapterError.sessionNotFound(session.id)
        }
        let project = GeminiProject(folder: folder, registry: layout.registry())
        guard let chat = project.chats.first(where: { $0.file == file }) else { throw AdapterError.sessionNotFound(session.id) }
        return .chat(project, chat)
    }

    private func requireWritable() throws {
        switch layout.probe() {
        case .readOnly(let reason): throw AdapterError.readOnly(kind, reason: reason)
        case .notInstalled: throw AdapterError.notInstalled(kind)
        case .ready: break
        }
    }
}

extension GeminiAdapter: RetentionReporting {
    public func retentionRule() -> RetentionRule? {
        let settings = GeminiSettings.load(from: layout.settings)
        guard settings.isEnabled else { return nil }
        let rule = settings.maxAge != nil
            ? "Gemini CLI deletes chats older than \(settings.maxAgeDescription)."
            : "Gemini CLI deletes chats beyond the newest \(settings.maxCount ?? 0) of each project."
        return RetentionRule(
            agent: kind,
            rule: rule,
            advice: "It sweeps a project when it starts there, and also removes chats without messages. Archiving compresses them but keeps their dates, so the sweep still applies. To keep them longer, raise general.sessionRetention.maxAge in Gemini CLI settings.",
            settingsFile: layout.settings,
            canArchive: true
        )
    }
}

private enum GeminiNote {
    static let chat = "Chat"
    static let subagents = "Subagent chats"
    static let toolOutputs = "Tool outputs"
    static let emptyChat = "Empty chat"
}
