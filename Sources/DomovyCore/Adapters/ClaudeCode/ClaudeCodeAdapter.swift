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
    public init(home: URL, expiringWindowDays: Int = 7) {
        self.init(
            configDirectory: home.appendingPathComponent(".claude", isDirectory: true),
            expiringWindowDays: expiringWindowDays,
            openHandles: LibprocOpenHandleChecker.shared,
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
        guard let result = await liveChecks(for: [session]).first else { throw AdapterError.sessionNotFound(session.id) }
        return try result.get()
    }

    /// A batch reads `history.jsonl`, `security/` and the liveness files once and asks one
    /// open-file question; each session gets what a check of its own would have got.
    public func liveChecks(for sessions: [Session]) async -> [Result<LiveCheckResult, any Error>] {
        let batch = Batch(adapter: self, desktop: .empty)
        let groups = sessions.map { session in
            Result { () throws -> [URL] in
                try requireOurs(session)
                return batch.artifacts(of: session).map(\.url)
            }
        }
        let checked = await batch.liveness(zip(sessions, groups).compactMap { session, group in
            (try? group.get()).map { (session.id, $0) }
        })
        var next = checked.makeIterator()
        return zip(sessions, groups).map { session, group in
            group.flatMap { _ in next.next().map { .success($0) } ?? .failure(AdapterError.sessionNotFound(session.id)) }
        }
    }

    public func deletePlan(for session: Session, destination: Destination = .trash) async throws -> Plan {
        guard let planned = await deletePlans(for: [session], destination: destination).first else {
            throw AdapterError.sessionNotFound(session.id)
        }
        return try planned.result.get()
    }

    /// A batch reads Claude Desktop's registry, `history.jsonl`, `security/`, each project
    /// folder and the liveness files once, asks one open-file question for every session and
    /// checks for Claude Desktop once. Each plan is exactly what a plan of its own would be; the
    /// executor checks again right before it changes anything.
    public func deletePlans(for sessions: [Session], destination: Destination) async -> [PlannedSession] {
        let writable = Result { try requireWritable() }
        let desktop = desktopSnapshot()
        let batch = Batch(adapter: self, desktop: desktop)
        var parts: [Result<DeleteParts, any Error>] = []
        for session in sessions {
            parts.append(Result {
                try requireOurs(session)
                try writable.get()
                return try deleteParts(for: session, artifacts: batch.artifacts(of: session), desktop: desktop, history: batch.shared.history)
            })
        }
        let found = zip(sessions, parts).compactMap { session, part in (try? part.get()).map { (session: session, parts: $0) } }
        let checked = await batch.liveness(found.map { ($0.session.id, $0.parts.moves.map(\.source)) })
        // Asked once, and only when a plan changes Claude Desktop's list.
        let blocking = found.contains { !$0.parts.removals.isEmpty } ? desktopProcesses.blockingReasons([ClaudeDesktopRegistry.processMatcher]) : []
        var next = checked.makeIterator()
        return zip(sessions, parts).map { session, part in
            PlannedSession(session: session, result: part.flatMap { part in
                guard let base = next.next() else { return .failure(AdapterError.sessionNotFound(session.id)) }
                let removals = part.removals
                return .success(Plan(
                    agent: kind,
                    sessionID: session.id,
                    action: .delete,
                    destination: destination,
                    moves: part.moves,
                    indexEdits: part.edits,
                    registryRemovals: removals,
                    remarks: part.remarks,
                    mustNotBeRunning: removals.isEmpty ? [] : [ClaudeDesktopRegistry.processMatcher],
                    liveCheck: Self.desktopChecked(base, blocking: removals.isEmpty ? nil : blocking),
                    scope: self.scope
                ))
            })
        }
    }

    /// What one session's delete plan moves and edits.
    private struct DeleteParts {
        var moves: [FileMove] = []
        var edits: [IndexEdit] = []
        var removals: [RegistryRemoval] = []
        var remarks: [String] = []
    }

    private func deleteParts(for session: Session, artifacts: [Artifact], desktop: ClaudeDesktopRegistry.Snapshot,
                             history: [String: HistoryLines]) throws -> DeleteParts {
        var parts = DeleteParts()
        for artifact in artifacts {
            // Defensive: collectArtifacts never produces protected paths, but a plan must prove it.
            if layout.isProtected(artifact.url) { throw AdapterError.protectedPathInPlan(artifact.url) }
            switch artifact.kind {
            case .file, .folder:
                parts.moves.append(FileMove(source: artifact.url, kind: artifact.kind, sizeBytes: artifact.sizeBytes, note: artifact.note))
            case .indexEntry where artifact.url == layout.history:
                if let edit = historyEdit(for: session.id, in: history) { parts.edits.append(edit) }
            case .indexEntry:
                guard let entry = desktop.entries.first(where: { $0.file == artifact.url }) else { continue }
                if case .readOnly(let reason) = desktop.status {
                    parts.remarks.append("Claude Desktop still lists this session: \(reason)")
                } else {
                    parts.removals.append(ClaudeDesktopRegistry.removal(of: entry, note: artifact.note))
                }
            }
        }
        if !parts.removals.isEmpty {
            parts.remarks.append("Claude Desktop stops listing this session. Its entry is backed up first, so undo puts it back.")
        }
        return parts
    }

    /// Compresses the session's cold files in place with APFS transparent compression.
    /// Claude Code reads them unchanged and can resume the session; mtimes stay, so its
    /// retention sweep still applies. `history.jsonl` is shared and stays as it is.
    public func archivePlan(for session: Session) async throws -> Plan {
        guard let planned = await archivePlans(for: [session]).first else { throw AdapterError.sessionNotFound(session.id) }
        return try planned.result.get()
    }

    /// A batch reads the shared files and the liveness files once and asks one open-file
    /// question; each plan is exactly what a plan of its own would be.
    public func archivePlans(for sessions: [Session]) async -> [PlannedSession] {
        let writable = Result { try requireWritable() }
        let batch = Batch(adapter: self, desktop: .empty)
        var parts: [Result<[FileCompression], any Error>] = []
        for session in sessions {
            parts.append(Result {
                try requireOurs(session)
                try writable.get()
                return try compressions(of: batch.artifacts(of: session))
            })
        }
        let checked = await batch.liveness(zip(sessions, parts).compactMap { session, part in
            (try? part.get()).map { (session.id, $0.map(\.file)) }
        })
        var next = checked.makeIterator()
        return zip(sessions, parts).map { session, part in
            PlannedSession(session: session, result: part.flatMap { compressions in
                guard let live = next.next() else { return .failure(AdapterError.sessionNotFound(session.id)) }
                return .success(Plan(
                    agent: kind,
                    sessionID: session.id,
                    action: .archive,
                    destination: nil,
                    moves: [],
                    indexEdits: [],
                    compressions: compressions,
                    liveCheck: live,
                    scope: self.scope
                ))
            })
        }
    }

    private func compressions(of artifacts: [Artifact]) throws -> [FileCompression] {
        var compressions: [FileCompression] = []
        for artifact in artifacts where Self.archivedNotes.contains(artifact.note) {
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
        return compressions
    }

    /// What a batch of artifacts, live checks or plans reads once: the shared files, each
    /// project folder's set-aside copies and the liveness files. Lives for one call only, so a
    /// plan never sees an older read than its batch.
    private final class Batch {
        let adapter: ClaudeCodeAdapter
        let shared: SharedFiles
        private var setAside: [URL: [String: [URL]]] = [:]

        init(adapter: ClaudeCodeAdapter, desktop: ClaudeDesktopRegistry.Snapshot) {
            self.adapter = adapter
            self.shared = SharedFiles(desktop: desktop, history: adapter.historyLines(), security: FileSystem.children(of: adapter.layout.security))
        }

        func artifacts(of session: Session) -> [Artifact] {
            let slug = session.transcriptURL.deletingLastPathComponent()
            if setAside[slug] == nil {
                var byID: [String: [URL]] = [:]
                for entry in FileSystem.children(of: slug) {
                    if let id = ClaudeCodeLayout.sessionID(ofSetAsideCopyNamed: entry.lastPathComponent) { byID[id, default: []].append(entry) }
                }
                setAside[slug] = byID
            }
            return adapter.collectArtifacts(id: session.id, transcript: session.transcriptURL, setAside: setAside[slug]?[session.id] ?? [], shared: shared)
        }

        /// One live check per session and its files: the liveness files read once, one
        /// open-file question for all.
        func liveness(_ groups: [(sessionID: String, urls: [URL])]) async -> [LiveCheckResult] {
            let liveness = adapter.liveness
            let markers = liveness.readMarkers()
            let holders = await openHandleHolders(of: groups.map(\.urls), checker: liveness.openHandles)
            return zip(groups, holders).map { group, holders in
                liveness.result(markerReasons: liveness.markerReasons(sessionID: group.sessionID, markers: markers), holders: holders)
            }
        }
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

    public func transcriptPage(of session: Session, limit: Int, before cursor: TranscriptCursor?, masking findings: [SecretFinding]) async throws -> Transcript {
        try requireOurs(session)
        return try TranscriptReader.readPage(session.transcriptURL, limit: limit, before: cursor, masking: findings)
    }

    /// Adds "Claude Desktop is running" to a live check when the plan changes Desktop's list.
    func desktopChecked(_ base: LiveCheckResult, touchesRegistry: Bool) async -> LiveCheckResult {
        guard touchesRegistry else { return base }
        return Self.desktopChecked(base, blocking: desktopProcesses.blockingReasons([ClaudeDesktopRegistry.processMatcher]))
    }

    /// `base` with the reasons Claude Desktop blocks for; `nil` when the plan leaves its list alone.
    static func desktopChecked(_ base: LiveCheckResult, blocking: [String]?) -> LiveCheckResult {
        guard let blocking else { return base }
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
    /// sessions, a batch of live checks or plans once for its sessions (one session: fresh).
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
    fileprivate func collectArtifacts(id: String, transcript: URL, setAside: [URL], shared: SharedFiles) -> [Artifact] {
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
    fileprivate func historyLines() -> [String: HistoryLines] {
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
