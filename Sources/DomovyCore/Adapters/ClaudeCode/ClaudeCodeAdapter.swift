import Foundation

/// Adapter for the Claude Code CLI (`~/.claude`). See PLAN.md section 5 for the storage map.
public struct ClaudeCodeAdapter: AgentAdapter {
    public let kind: AgentKind = .claudeCode
    public let root: URL

    /// Sessions whose retention deadline is this close are reported as `.expiring`.
    public let expiringWindowDays: Int
    let layout: ClaudeCodeLayout
    let liveness: ClaudeCodeLiveness
    /// Claude Desktop's list of Claude Code sessions, when this home has one.
    let desktopRegistry: ClaudeDesktopRegistry?
    /// Running-Claude-Desktop check before a plan touches its registry.
    let desktopProcesses: any RunningProcessLister
    let now: @Sendable () -> Date

    /// - Parameters:
    ///   - configDirectory: the `.claude` folder to scan. Tests pass a copy of a fixture.
    ///   - openHandles: open-file-handle check; libproc by default, a stub in tests.
    ///   - processes: pid existence check used to ignore stale liveness markers.
    ///   - desktopRegistry: Claude Desktop's session list to link sessions to; `nil` for none.
    ///   - desktopProcesses: running-Claude-Desktop check; libproc by default, fixed in tests.
    ///   - now: clock, injectable for tests.
    public init(
        configDirectory: URL,
        expiringWindowDays: Int = 7,
        openHandles: any OpenHandleChecker = LibprocOpenHandleChecker(),
        processes: any ProcessProbe = KillProcessProbe(),
        desktopRegistry: ClaudeDesktopRegistry? = nil,
        desktopProcesses: any RunningProcessLister = LibprocProcessLister(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.root = configDirectory.standardizedFileURL
        self.expiringWindowDays = expiringWindowDays
        self.layout = ClaudeCodeLayout(root: self.root)
        self.liveness = ClaudeCodeLiveness(layout: layout, openHandles: openHandles, processes: processes)
        self.desktopRegistry = desktopRegistry
        self.desktopProcesses = desktopProcesses
        self.now = now
    }

    /// Convenience for a home directory: `<home>/.claude`, linked to Claude Desktop's list.
    public init(home: URL) {
        self.init(
            configDirectory: home.appendingPathComponent(".claude", isDirectory: true),
            desktopRegistry: ClaudeDesktopRegistry(home: home)
        )
    }

    /// `~/.claude`, and Claude Desktop's session list when a delete takes a session off it.
    public var scope: [URL] {
        [root] + (desktopRegistry.map { [$0.root] } ?? [])
    }

    /// Claude Desktop's registry as it is now, or an empty one.
    func desktopSnapshot() -> ClaudeDesktopRegistry.Snapshot {
        desktopRegistry?.snapshot() ?? .empty
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
        let shared = SharedFiles(desktop: desktopSnapshot(), history: historyLines(), security: FileSystem.children(of: layout.security))
        var found: [(id: String, transcript: URL, slug: URL, artifacts: [Artifact])] = []
        for slug in FileSystem.children(of: layout.projects) where FileSystem.isDirectory(slug) {
            let entries = FileSystem.children(of: slug)
            var setAside: [String: [URL]] = [:]
            for entry in entries {
                if let id = ClaudeCodeLayout.sessionID(ofSetAsideCopyNamed: entry.lastPathComponent) { setAside[id, default: []].append(entry) }
            }
            for entry in entries {
                guard let id = ClaudeCodeLayout.sessionID(ofTranscriptNamed: entry.lastPathComponent) else { continue }
                let artifacts = collectArtifacts(id: id, transcript: entry, setAside: setAside[id] ?? [], shared: shared)
                found.append((id, entry, slug, artifacts))
            }
        }
        // One read of the liveness files and one open-file question for the whole listing.
        let markers = liveness.readMarkers()
        let holders = await openHandleHolders(of: found.map { $0.artifacts.map(\.url) }, checker: liveness.openHandles)
        return zip(found, holders).map { item, holders in
            let live = liveness.result(markerReasons: liveness.markerReasons(sessionID: item.id, markers: markers), holders: holders)
            return makeSession(id: item.id, transcript: item.transcript, slug: item.slug, artifacts: item.artifacts, live: live,
                               settings: settings, desktop: shared.desktop)
        }
        .sorted { $0.lastActive > $1.lastActive }
    }

    public func artifacts(of session: Session) async throws -> [Artifact] {
        try requireOurs(session)
        return collectArtifacts(id: session.id, transcript: session.transcriptURL, desktop: desktopSnapshot())
    }

    public func liveCheck(_ session: Session) async throws -> LiveCheckResult {
        try requireOurs(session)
        let urls = collectArtifacts(id: session.id, transcript: session.transcriptURL).map(\.url)
        return await liveness.check(sessionID: session.id, artifactURLs: urls)
    }

    public func deletePlan(for session: Session, destination: Destination = .trash) async throws -> Plan {
        try requireOurs(session)
        try requireWritable()

        let desktop = desktopSnapshot()
        let artifacts = collectArtifacts(id: session.id, transcript: session.transcriptURL, desktop: desktop)
        var moves: [FileMove] = []
        var edits: [IndexEdit] = []
        var removals: [RegistryRemoval] = []
        var remarks: [String] = []
        for artifact in artifacts {
            // Defensive: collectArtifacts never produces protected paths, but a plan must prove it.
            if layout.isProtected(artifact.url) { throw AdapterError.protectedPathInPlan(artifact.url) }
            switch artifact.kind {
            case .file, .folder:
                moves.append(FileMove(source: artifact.url, kind: artifact.kind, sizeBytes: artifact.sizeBytes, note: artifact.note))
            case .indexEntry where artifact.url == layout.history:
                if let edit = historyEdit(for: session.id) { edits.append(edit) }
            case .indexEntry:
                guard let entry = desktop.entries.first(where: { $0.file == artifact.url }) else { continue }
                if case .readOnly(let reason) = desktop.status {
                    remarks.append("Claude Desktop still lists this session: \(reason)")
                } else {
                    removals.append(ClaudeDesktopRegistry.removal(of: entry, note: artifact.note))
                }
            }
        }
        if !removals.isEmpty {
            remarks.append("Claude Desktop stops listing this session. Its entry is backed up first, so undo puts it back.")
        }
        let live = await desktopChecked(
            await liveness.check(sessionID: session.id, artifactURLs: moves.map(\.source)),
            touchesRegistry: !removals.isEmpty
        )
        return Plan(
            agent: kind,
            sessionID: session.id,
            action: .delete,
            destination: destination,
            moves: moves,
            indexEdits: edits,
            registryRemovals: removals,
            remarks: remarks,
            mustNotBeRunning: removals.isEmpty ? [] : [ClaudeDesktopRegistry.processMatcher],
            liveCheck: live,
            scope: self.scope
        )
    }

    /// Compresses the session's cold files in place with APFS transparent compression.
    /// Claude Code reads them unchanged and can resume the session; mtimes stay, so its
    /// retention sweep still applies. `history.jsonl` is shared and stays as it is.
    public func archivePlan(for session: Session) async throws -> Plan {
        try requireOurs(session)
        try requireWritable()

        var compressions: [FileCompression] = []
        for artifact in collectArtifacts(id: session.id, transcript: session.transcriptURL)
        where Self.archivedNotes.contains(artifact.note) {
            for file in APFSCompression.regularFiles(at: artifact.url) {
                if layout.isProtected(file) { throw AdapterError.protectedPathInPlan(file) }
                guard !APFSCompression.isCompressed(file),
                      FileSystem.size(of: file) > APFSCompression.minimumUsefulSize else { continue }
                compressions.append(FileCompression(
                    file: file,
                    sizeBytes: APFSCompression.allocatedBytes(of: file),
                    estimatedBytes: APFSCompression.estimatedCompressedBytes(of: file),
                    modificationTime: FileSystem.modificationTime(of: file),
                    note: artifact.note
                ))
            }
        }
        let live = await liveness.check(sessionID: session.id, artifactURLs: compressions.map(\.file))
        return Plan(
            agent: kind,
            sessionID: session.id,
            action: .archive,
            destination: nil,
            moves: [],
            indexEdits: [],
            compressions: compressions,
            liveCheck: live,
            scope: self.scope
        )
    }

    /// Artifacts worth compressing: transcripts and their bulky companions. Small state the
    /// agent may still rewrite (session env, security state) and shared indexes are left out.
    private static let archivedNotes: Set<String> = [
        ArtifactNote.transcript, ArtifactNote.companions, ArtifactNote.setAside,
        ArtifactNote.checkpoints, ArtifactNote.uploads,
    ]

    public func transcript(of session: Session, limit: Int, masking findings: [SecretFinding]) async throws -> Transcript {
        try requireOurs(session)
        return try TranscriptReader(maxMessages: limit).read(session.transcriptURL, masking: findings)
    }

    /// Adds "Claude Desktop is running" to a live check when the plan changes Desktop's list.
    func desktopChecked(_ base: LiveCheckResult, touchesRegistry: Bool) async -> LiveCheckResult {
        guard touchesRegistry else { return base }
        let blocking = desktopProcesses.blockingReasons([ClaudeDesktopRegistry.processMatcher])
        return LiveCheckResult(
            isLive: base.isLive || !blocking.isEmpty,
            reasons: base.reasons + blocking,
            checkedSignals: base.checkedSignals + ["Claude Desktop processes"],
            openHandles: base.openHandles
        )
    }

    /// Claude Code's retention period in days (`cleanupPeriodDays`, default 30).
    public func cleanupPeriodDays() -> Int {
        ClaudeCodeSettings.load(from: layout.settings).cleanupPeriodDays
    }

    // MARK: Building sessions

    private func makeSession(id: String, transcript: URL, slug: URL, artifacts: [Artifact], live: LiveCheckResult,
                             settings: ClaudeCodeSettings, desktop: ClaudeDesktopRegistry.Snapshot) -> Session {
        let header = ClaudeCodeTranscript.readHeader(of: transcript)
        let link = Self.newest(desktop.byCLISessionID[id] ?? []).map { DesktopLink(file: $0.file, title: $0.title, isArchived: $0.isArchived) }
        let size = artifacts.reduce(0) { $0 + $1.sizeBytes }
        let lastActive = FileSystem.modificationDate(of: transcript) ?? .distantPast
        let expiresAt = lastActive.addingTimeInterval(TimeInterval(settings.cleanupPeriodDays) * 86_400)

        let archived = APFSCompression.isCompressed(transcript)

        // Expiring wins over archived: compression keeps the mtime, so the sweep still comes.
        let status: Session.Status
        if live.isLive {
            status = .live
        } else if expiresAt.timeIntervalSince(now()) <= TimeInterval(expiringWindowDays) * 86_400 {
            status = .expiring
        } else if archived {
            status = .archived
        } else {
            status = .idle
        }
        return Session(
            id: id,
            agent: kind,
            // Desktop's title is the one the user sees in its sidebar.
            title: link?.title ?? header.title,
            projectPath: header.cwd ?? Self.guessProjectPath(fromSlug: slug.lastPathComponent),
            lastActive: lastActive,
            sizeBytes: size,
            status: status,
            expiresAt: expiresAt,
            transcriptURL: transcript,
            isArchived: archived,
            desktop: link
        )
    }

    /// The most recently modified registry entry, when Desktop lists a session more than once.
    static func newest(_ entries: [DesktopRegistryEntry]) -> DesktopRegistryEntry? {
        entries.max { ($0.modificationDate ?? .distantPast, $1.file.path) < ($1.modificationDate ?? .distantPast, $0.file.path) }
    }

    /// The slug replaces every `/` (and other punctuation) with `-`, so this is lossy; the
    /// transcript's `cwd` is preferred when present.
    private static func guessProjectPath(fromSlug slug: String) -> String {
        slug.replacingOccurrences(of: "-", with: "/")
    }

    // MARK: Artifacts

    /// Every file, folder and index entry that belongs to one session. Protected paths
    /// (`memory/`, `plugins/`, ...) are never visited.
    func collectArtifacts(id: String, transcript: URL, desktop: ClaudeDesktopRegistry.Snapshot = .empty) -> [Artifact] {
        let slug = transcript.deletingLastPathComponent()
        let setAside = FileSystem.children(of: slug).filter { ClaudeCodeLayout.sessionID(ofSetAsideCopyNamed: $0.lastPathComponent) == id }
        let shared = SharedFiles(desktop: desktop, history: historyLines(), security: FileSystem.children(of: layout.security))
        return collectArtifacts(id: id, transcript: transcript, setAside: setAside, shared: shared)
    }

    /// What every session's artifacts are looked up in. A listing reads it once for all its
    /// sessions; artifacts, live checks and plans read it fresh for the one session they need.
    struct SharedFiles {
        let desktop: ClaudeDesktopRegistry.Snapshot
        /// `history.jsonl` lines by lowercased session id.
        let history: [String: HistoryLines]
        /// The `security/` folder's files.
        let security: [URL]
    }

    /// Zero-based line numbers of one session in `history.jsonl` and their bytes.
    struct HistoryLines {
        var indices: [Int] = []
        var bytes: Int64 = 0
    }

    /// `collectArtifacts` with the session's set-aside copies (`.orphaned-*`, `.superseded-*`
    /// next to the transcript) and the shared files already read.
    private func collectArtifacts(id: String, transcript: URL, setAside: [URL], shared: SharedFiles) -> [Artifact] {
        var artifacts: [Artifact] = []
        func add(_ url: URL, _ kind: Artifact.Kind, _ note: String) {
            guard FileSystem.exists(url), !layout.isProtected(url) else { return }
            artifacts.append(Artifact(url: url, kind: kind, sizeBytes: FileSystem.size(of: url), note: note))
        }

        let slug = transcript.deletingLastPathComponent()
        add(transcript, .file, ArtifactNote.transcript)
        add(slug.appendingPathComponent(id, isDirectory: true), .folder, ArtifactNote.companions)
        for sibling in setAside {
            add(sibling, .file, ArtifactNote.setAside)
        }
        add(layout.fileHistory.appendingPathComponent(id, isDirectory: true), .folder, ArtifactNote.checkpoints)
        add(layout.uploads.appendingPathComponent(id, isDirectory: true), .folder, ArtifactNote.uploads)
        add(layout.devMods.appendingPathComponent(id, isDirectory: true), .folder, "Development modifications")
        let env = layout.sessionEnv.appendingPathComponent(id)
        add(env, FileSystem.isDirectory(env) ? .folder : .file, "Session environment")
        for file in shared.security where file.lastPathComponent.hasPrefix("security_warnings_state_\(id).") {
            add(file, .file, "Security warning state")
        }
        if let edit = historyEdit(for: id, in: shared.history) {
            artifacts.append(Artifact(url: edit.file, kind: .indexEntry, sizeBytes: edit.removedBytes, note: edit.note,
                                      match: IndexMatch(key: edit.matchKey, value: edit.matchValue)))
        }
        for entry in shared.desktop.byCLISessionID[id] ?? [] {
            artifacts.append(Artifact(url: entry.file, kind: .indexEntry, sizeBytes: entry.sizeBytes, note: ArtifactNote.desktopEntry))
        }
        return artifacts
    }

    /// Lines of `history.jsonl` that reference the session, or `nil` when there are none.
    private func historyEdit(for id: String) -> IndexEdit? {
        historyEdit(for: id, in: historyLines())
    }

    private func historyEdit(for id: String, in history: [String: HistoryLines]) -> IndexEdit? {
        guard let lines = history[id.lowercased()], !lines.indices.isEmpty else { return nil }
        let indices = lines.indices
        return IndexEdit(
            file: layout.history,
            lineNumbers: indices,
            matchKey: "sessionId",
            matchValue: id,
            removedBytes: lines.bytes,
            note: "\(indices.count) \(indices.count == 1 ? "entry" : "entries") in history.jsonl; the file itself stays"
        )
    }

    /// Every line of `history.jsonl` by the session it references, parsed once. Lines match
    /// as in `JSONLines.indices`: `sessionId` equal ignoring case.
    private func historyLines() -> [String: HistoryLines] {
        guard let data = try? Data(contentsOf: layout.history) else { return [:] }
        var result: [String: HistoryLines] = [:]
        for (index, line) in JSONLines.split(data).lines.enumerated() {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = (object["sessionId"] as? String)?.lowercased() else { continue }
            result[id, default: HistoryLines()].indices.append(index)
            result[id, default: HistoryLines()].bytes += Int64(line.count) + 1
        }
        return result
    }

    func requireWritable() throws {
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

/// Artifact notes shown to the user; the archive plan selects artifacts by them.
private enum ArtifactNote {
    static let transcript = "Transcript"
    static let companions = "Subagent transcripts, tool results and MCP tasks"
    static let setAside = "Set-aside copy of the transcript"
    static let checkpoints = "Checkpoint snapshots"
    static let uploads = "Uploaded files"
    static let desktopEntry = "Desktop registry entry, file removed"
}
