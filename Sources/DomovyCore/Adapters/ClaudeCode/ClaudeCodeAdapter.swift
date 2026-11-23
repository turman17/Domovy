import Foundation

/// Adapter for the Claude Code CLI (`~/.claude`). See PLAN.md section 5 for the storage map.
public struct ClaudeCodeAdapter: AgentAdapter {
    public let kind: AgentKind = .claudeCode
    public let root: URL

    /// Sessions whose retention deadline is this close are reported as `.expiring`.
    public let expiringWindowDays: Int
    let layout: ClaudeCodeLayout
    let liveness: ClaudeCodeLiveness
    let now: @Sendable () -> Date

    /// - Parameters:
    ///   - configDirectory: the `.claude` folder to scan. Tests pass a copy of a fixture.
    ///   - openHandles: open-file-handle check; libproc by default, a stub in tests.
    ///   - processes: pid existence check used to ignore stale liveness markers.
    ///   - now: clock, injectable for tests.
    public init(
        configDirectory: URL,
        expiringWindowDays: Int = 7,
        openHandles: any OpenHandleChecker = LibprocOpenHandleChecker(),
        processes: any ProcessProbe = KillProcessProbe(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.root = configDirectory.standardizedFileURL
        self.expiringWindowDays = expiringWindowDays
        self.layout = ClaudeCodeLayout(root: self.root)
        self.liveness = ClaudeCodeLiveness(layout: layout, openHandles: openHandles, processes: processes)
        self.now = now
    }

    /// Convenience for a home directory: `<home>/.claude`.
    public init(home: URL) {
        self.init(configDirectory: home.appendingPathComponent(".claude", isDirectory: true))
    }

    // MARK: AgentAdapter

    public func status() async -> AdapterStatus {
        layout.probe()
    }

    public func sessions() async throws -> [Session] {
        switch layout.probe() {
        case .notInstalled: throw AdapterError.notInstalled(kind)
        case .ready, .readOnly: break
        }
        let settings = ClaudeCodeSettings.load(from: layout.settings)
        var result: [Session] = []
        for slug in FileSystem.children(of: layout.projects) where FileSystem.isDirectory(slug) {
            for entry in FileSystem.children(of: slug) {
                guard let id = ClaudeCodeLayout.sessionID(ofTranscriptNamed: entry.lastPathComponent) else { continue }
                result.append(await makeSession(id: id, transcript: entry, slug: slug, settings: settings))
            }
        }
        return result.sorted { $0.lastActive > $1.lastActive }
    }

    public func artifacts(of session: Session) async throws -> [Artifact] {
        try requireOurs(session)
        return collectArtifacts(id: session.id, transcript: session.transcriptURL)
    }

    public func liveCheck(_ session: Session) async throws -> LiveCheckResult {
        try requireOurs(session)
        let urls = collectArtifacts(id: session.id, transcript: session.transcriptURL).map(\.url)
        return await liveness.check(sessionID: session.id, artifactURLs: urls)
    }

    public func deletePlan(for session: Session, destination: Destination = .trash) async throws -> Plan {
        try requireOurs(session)
        if case .readOnly(let reason) = layout.probe() { throw AdapterError.readOnly(kind, reason: reason) }
        if case .notInstalled = layout.probe() { throw AdapterError.notInstalled(kind) }

        let artifacts = collectArtifacts(id: session.id, transcript: session.transcriptURL)
        var moves: [FileMove] = []
        var edits: [IndexEdit] = []
        for artifact in artifacts {
            // Defensive: collectArtifacts never produces protected paths, but a plan must prove it.
            if layout.isProtected(artifact.url) { throw AdapterError.protectedPathInPlan(artifact.url) }
            switch artifact.kind {
            case .file, .folder:
                moves.append(FileMove(source: artifact.url, kind: artifact.kind, sizeBytes: artifact.sizeBytes, note: artifact.note))
            case .indexEntry:
                if let edit = historyEdit(for: session.id) { edits.append(edit) }
            }
        }
        let live = await liveness.check(sessionID: session.id, artifactURLs: moves.map(\.source))
        return Plan(
            agent: kind,
            sessionID: session.id,
            action: .delete,
            destination: destination,
            moves: moves,
            indexEdits: edits,
            liveCheck: live
        )
    }

    public func archivePlan(for session: Session) async throws -> Plan {
        try requireOurs(session)
        throw AdapterError.notImplemented(kind, feature: "archive")
    }

    public func transcript(of session: Session, limit: Int) async throws -> Transcript {
        try requireOurs(session)
        return try TranscriptReader(maxMessages: limit).read(session.transcriptURL)
    }

    /// Claude Code's retention period in days (`cleanupPeriodDays`, default 30).
    public func cleanupPeriodDays() -> Int {
        ClaudeCodeSettings.load(from: layout.settings).cleanupPeriodDays
    }

    public func footprint() async throws -> Footprint {
        guard FileSystem.exists(root) else { throw AdapterError.notInstalled(kind) }
        func category(_ name: String, _ url: URL, _ disposition: Footprint.Disposition, _ note: String) -> Footprint.Category? {
            guard FileSystem.exists(url) else { return nil }
            return Footprint.Category(name: name, url: url, sizeBytes: FileSystem.size(of: url), disposition: disposition, note: note)
        }
        let categories: [Footprint.Category?] = [
            category("Transcripts", layout.projects, .consequences, "Session transcripts and auto memory. Deleting a session removes its history."),
            category("Checkpoints", layout.fileHistory, .consequences, "File snapshots for /rewind, one folder per session."),
            category("Uploads", layout.uploads, .consequences, "Files attached to sessions."),
            category("Dev mods", layout.devMods, .consequences, "Per-session development modifications."),
            category("Session environments", layout.sessionEnv, .safe, "Environment metadata per session; swept by Claude Code itself."),
            category("Security state", layout.security, .consequences, "Security warning state and the agent SDK venv."),
            category("Prompt history", layout.history, .consequences, "Typed prompts for the prompt history picker."),
            category("Paste cache", root.appendingPathComponent("paste-cache"), .safe, "Cached pastes; swept by age."),
            category("Shell snapshots", root.appendingPathComponent("shell-snapshots"), .safe, "Left behind after crashes; swept by age."),
            category("Backups", root.appendingPathComponent("backups"), .safe, "Copies of ~/.claude.json; Claude Code keeps the newest five."),
            category("Plugins", root.appendingPathComponent("plugins"), .keep, "Installed plugins. Claude Code needs them to run."),
            category("Skills", root.appendingPathComponent("skills"), .keep, "Installed skills. Claude Code needs them to run."),
        ]
        return Footprint(agent: kind, root: root, categories: categories.compactMap { $0 })
    }

    // MARK: Building sessions

    private func makeSession(id: String, transcript: URL, slug: URL, settings: ClaudeCodeSettings) async -> Session {
        let header = ClaudeCodeTranscript.readHeader(of: transcript)
        let artifacts = collectArtifacts(id: id, transcript: transcript)
        let size = artifacts.reduce(0) { $0 + $1.sizeBytes }
        let lastActive = FileSystem.modificationDate(of: transcript) ?? .distantPast
        let expiresAt = lastActive.addingTimeInterval(TimeInterval(settings.cleanupPeriodDays) * 86_400)
        let live = await liveness.check(sessionID: id, artifactURLs: artifacts.map(\.url))

        let status: Session.Status
        if live.isLive {
            status = .live
        } else if expiresAt.timeIntervalSince(now()) <= TimeInterval(expiringWindowDays) * 86_400 {
            status = .expiring
        } else {
            status = .idle
        }
        return Session(
            id: id,
            agent: kind,
            title: header.title,
            projectPath: header.cwd ?? Self.guessProjectPath(fromSlug: slug.lastPathComponent),
            lastActive: lastActive,
            sizeBytes: size,
            status: status,
            expiresAt: expiresAt,
            transcriptURL: transcript
        )
    }

    /// The slug replaces every `/` (and other punctuation) with `-`, so this is lossy; the
    /// transcript's `cwd` is preferred when present.
    private static func guessProjectPath(fromSlug slug: String) -> String {
        slug.replacingOccurrences(of: "-", with: "/")
    }

    // MARK: Artifacts

    /// Every file, folder and index entry that belongs to one session. Protected paths
    /// (`memory/`, `plugins/`, ...) are never visited.
    private func collectArtifacts(id: String, transcript: URL) -> [Artifact] {
        var artifacts: [Artifact] = []
        func add(_ url: URL, _ kind: Artifact.Kind, _ note: String) {
            guard FileSystem.exists(url), !layout.isProtected(url) else { return }
            artifacts.append(Artifact(url: url, kind: kind, sizeBytes: FileSystem.size(of: url), note: note))
        }

        let slug = transcript.deletingLastPathComponent()
        add(transcript, .file, "Transcript")
        add(slug.appendingPathComponent(id, isDirectory: true), .folder, "Subagent transcripts, tool results and MCP tasks")
        for sibling in FileSystem.children(of: slug) where ClaudeCodeLayout.sessionID(ofSetAsideCopyNamed: sibling.lastPathComponent) == id {
            add(sibling, .file, "Set-aside copy of the transcript")
        }
        add(layout.fileHistory.appendingPathComponent(id, isDirectory: true), .folder, "Checkpoint snapshots")
        add(layout.uploads.appendingPathComponent(id, isDirectory: true), .folder, "Uploaded files")
        add(layout.devMods.appendingPathComponent(id, isDirectory: true), .folder, "Development modifications")
        let env = layout.sessionEnv.appendingPathComponent(id)
        add(env, FileSystem.isDirectory(env) ? .folder : .file, "Session environment")
        for file in FileSystem.children(of: layout.security) where file.lastPathComponent.hasPrefix("security_warnings_state_\(id).") {
            add(file, .file, "Security warning state")
        }
        if let edit = historyEdit(for: id) {
            artifacts.append(Artifact(url: edit.file, kind: .indexEntry, sizeBytes: edit.removedBytes, note: edit.note))
        }
        return artifacts
    }

    /// Lines of `history.jsonl` that reference the session, or `nil` when there are none.
    private func historyEdit(for id: String) -> IndexEdit? {
        guard let data = try? Data(contentsOf: layout.history) else { return nil }
        let split = JSONLines.split(data)
        let indices = JSONLines.indices(in: split.lines, where: "sessionId", equals: id)
        guard !indices.isEmpty else { return nil }
        let bytes = indices.reduce(Int64(0)) { $0 + Int64(split.lines[$1].count) + 1 }
        return IndexEdit(
            file: layout.history,
            lineNumbers: indices,
            matchKey: "sessionId",
            matchValue: id,
            removedBytes: bytes,
            note: "\(indices.count) \(indices.count == 1 ? "entry" : "entries") in history.jsonl; the file itself stays"
        )
    }

    private func requireOurs(_ session: Session) throws {
        guard session.agent == kind, FileSystem.relativePath(of: session.transcriptURL, under: root) != nil else {
            throw AdapterError.sessionNotFound(session.id)
        }
    }
}
