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
    public init(home: URL, expiringWindowDays: Int = 7) {
        self.init(geminiHome: home.appendingPathComponent(".gemini", isDirectory: true), expiringWindowDays: expiringWindowDays,
                  openHandles: LibprocOpenHandleChecker.shared)
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
        // Artifacts first, so one open-file question covers the whole listing.
        var rows: [(artifacts: [Artifact], make: (LiveCheckResult) -> Session)] = []
        for project in projects {
            let due = project.dueForSweep(settings)
            for chat in project.chats where !grouped.contains(chat.file) {
                let artifacts = collectArtifacts(chat, in: project)
                let id = ids[chat.file] ?? chat.file.lastPathComponent
                rows.append((artifacts.filter { $0.kind != .indexEntry }, { live in
                    makeSession(chat, id: id, project: project, artifacts: artifacts, live: live, settings: settings, due: due[chat.file])
                }))
            }
        }
        for group in groups {
            let artifacts = collectArtifacts(group)
            rows.append((artifacts, { live in makeSession(group, artifacts: artifacts, live: live, settings: settings) }))
        }
        let holders = await openHandleHolders(of: rows.map { $0.artifacts.map(\.url) }, checker: openHandles)
        return zip(rows, holders).map { row, holders in row.make(liveness(holders: holders)) }
            .sorted { $0.lastActive > $1.lastActive }
    }

    public func artifacts(of session: Session) async throws -> [Artifact] {
        artifacts(of: try locate(session))
    }

    private func artifacts(of target: Target) -> [Artifact] {
        switch target {
        case .chat(let project, let chat): collectArtifacts(chat, in: project)
        case .group(let group): collectArtifacts(group)
        }
    }

    public func liveCheck(_ session: Session) async throws -> LiveCheckResult {
        guard let result = await liveChecks(for: [session]).first else { throw AdapterError.sessionNotFound(session.id) }
        return try result.get()
    }

    /// A batch reads each project folder once and asks one open-file question.
    public func liveChecks(for sessions: [Session]) async -> [Result<LiveCheckResult, any Error>] {
        let lookup = TargetLookup(layout: layout)
        let files = sessions.map { session in
            Result { () throws -> [URL] in
                artifacts(of: try locate(session, in: lookup)).filter { $0.kind != .indexEntry }.map(\.url)
            }
        }
        let holders = await openHandleHolders(of: files.compactMap { try? $0.get() }, checker: openHandles)
        var next = holders.makeIterator()
        return zip(sessions, files).map { session, files in
            files.flatMap { _ in next.next().map { .success(liveness(holders: $0)) } ?? .failure(AdapterError.sessionNotFound(session.id)) }
        }
    }

    /// Moves the chat and what Gemini CLI keys by its id (or every chat of a group).
    public func deletePlan(for session: Session, destination: Destination = .trash) async throws -> Plan {
        guard let planned = await deletePlans(for: [session], destination: destination).first else {
            throw AdapterError.sessionNotFound(session.id)
        }
        return try planned.result.get()
    }

    /// A batch reads each project folder once, asks one open-file question for every chat and
    /// checks for Gemini CLI once. Each plan gets exactly what its own question would have got;
    /// the executor checks again right before it moves anything.
    public func deletePlans(for sessions: [Session], destination: Destination) async -> [PlannedSession] {
        do {
            try requireWritable()
        } catch {
            return sessions.map { PlannedSession(session: $0, result: .failure(error)) }
        }
        let lookup = TargetLookup(layout: layout)
        var found: [(session: Session, target: Target, files: [Artifact])?] = []
        var failures: [Session.ID: any Error] = [:]
        for session in sessions {
            do {
                let target = try locate(session, in: lookup)
                let files = artifacts(of: target).filter { $0.kind != .indexEntry }
                for artifact in files where layout.isProtected(artifact.url) { throw AdapterError.protectedPathInPlan(artifact.url) }
                found.append((session, target, files))
            } catch {
                failures[session.id] = error
                found.append(nil)
            }
        }
        let located = found.compactMap { $0 }
        let holders = await openHandleHolders(of: located.map { $0.files.map(\.url) }, checker: openHandles)
        let blocking = processes.blockingReasons([Self.processMatcher])
        var plans: [Session.ID: Plan] = [:]
        for (item, holders) in zip(located, holders) {
            let base = liveness(holders: holders)
            let live = LiveCheckResult(isLive: base.isLive || !blocking.isEmpty, reasons: base.reasons + blocking,
                                       checkedSignals: base.checkedSignals + ["Gemini CLI processes"], openHandles: base.openHandles)
            let remarks: [String]
            switch item.target {
            case .chat(let project, let chat): remarks = sharedRemarks(chat, in: project)
            case .group(let group): remarks = groupRemarks(group)
            }
            let moves = item.files.map { FileMove(source: $0.url, kind: $0.kind, sizeBytes: $0.sizeBytes, note: $0.note) }
            plans[item.session.id] = Plan(agent: kind, sessionID: item.session.id, action: .delete, destination: destination, moves: moves,
                                          indexEdits: [], remarks: remarks, mustNotBeRunning: [Self.processMatcher], liveCheck: live, scope: self.scope)
        }
        return sessions.map { session in
            if let plan = plans[session.id] { return PlannedSession(session: session, result: .success(plan)) }
            return PlannedSession(session: session, result: .failure(failures[session.id] ?? AdapterError.sessionNotFound(session.id)))
        }
    }

    /// Compresses the chat and its bulky companions in place with APFS transparent compression.
    /// Gemini CLI reads them unchanged and can resume; modification times stay as they were.
    public func archivePlan(for session: Session) async throws -> Plan {
        guard let planned = await archivePlans(for: [session]).first else { throw AdapterError.sessionNotFound(session.id) }
        return try planned.result.get()
    }

    /// A batch reads each project folder once and asks one open-file question for every chat.
    public func archivePlans(for sessions: [Session]) async -> [PlannedSession] {
        let writable = Result { try requireWritable() }
        let lookup = TargetLookup(layout: layout)
        let parts = sessions.map { session in
            Result { () throws -> [FileCompression] in
                let target = try locate(session, in: lookup)
                try writable.get()
                return try compressions(of: artifacts(of: target))
            }
        }
        let holders = await openHandleHolders(of: parts.compactMap { try? $0.get().map(\.file) }, checker: openHandles)
        var next = holders.makeIterator()
        return zip(sessions, parts).map { session, part in
            PlannedSession(session: session, result: part.flatMap { compressions in
                guard let holders = next.next() else { return .failure(AdapterError.sessionNotFound(session.id)) }
                return .success(Plan(agent: kind, sessionID: session.id, action: .archive, destination: nil, moves: [], indexEdits: [],
                                     compressions: compressions, liveCheck: liveness(holders: holders), scope: self.scope))
            })
        }
    }

    private func compressions(of artifacts: [Artifact]) throws -> [FileCompression] {
        var compressions: [FileCompression] = []
        for artifact in artifacts where Self.archivedNotes.contains(artifact.note) {
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
        return compressions
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

    private func makeSession(_ chat: GeminiProject.Chat, id: String, project: GeminiProject, artifacts: [Artifact], live: LiveCheckResult,
                             settings: GeminiSettings, due: String?) -> Session {
        let size = artifacts.filter { $0.kind != .indexEntry }.reduce(Int64(0)) { $0 + $1.sizeBytes }
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
    private func makeSession(_ group: GeminiChatGroup, artifacts: [Artifact], live: LiveCheckResult, settings: GeminiSettings) -> Session {
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
    /// without keeping it open, so delete also requires Gemini CLI to be quit. The live check
    /// from the holders of the session's files (`nil`: the check could not run).
    private func liveness(holders: [OpenHandleHolder]?) -> LiveCheckResult {
        var reasons: [String] = []
        let status: LiveCheckResult.OpenHandleStatus
        if let holders {
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

    enum Target {
        case chat(GeminiProject, GeminiProject.Chat)
        case group(GeminiChatGroup)
    }

    /// Project folders and chat groups read on first use, then shared by every session of a
    /// batch. Lives for one call only, so a plan never sees an older read than its batch.
    private final class TargetLookup {
        let layout: GeminiLayout
        private lazy var registry = layout.registry()
        private var projects: [URL: GeminiProject] = [:]
        private(set) lazy var groups: [GeminiChatGroup] = GeminiChatGroup.groups(in: layout.projectFolders().map(project(in:)))

        init(layout: GeminiLayout) { self.layout = layout }

        func project(in folder: URL) -> GeminiProject {
            let key = folder.standardizedFileURL
            if let project = projects[key] { return project }
            let project = GeminiProject(folder: key, registry: registry)
            projects[key] = project
            return project
        }
    }

    private func locate(_ session: Session) throws -> Target {
        try locate(session, in: TargetLookup(layout: layout))
    }

    private func locate(_ session: Session, in lookup: TargetLookup) throws -> Target {
        guard session.agent == kind else { throw AdapterError.sessionNotFound(session.id) }
        if session.memberCount > 1 || session.id.hasSuffix(GeminiChatGroup.idSuffix) {
            if let group = lookup.groups.first(where: { $0.id == session.id }) { return .group(group) }
            if session.memberCount > 1 { throw AdapterError.sessionNotFound(session.id) }
        }
        let file = session.transcriptURL.standardizedFileURL
        let folder = file.deletingLastPathComponent().deletingLastPathComponent()
        guard FileSystem.relativePath(of: file, under: layout.tmp) != nil, FileSystem.exists(file) else {
            throw AdapterError.sessionNotFound(session.id)
        }
        let project = lookup.project(in: folder)
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
