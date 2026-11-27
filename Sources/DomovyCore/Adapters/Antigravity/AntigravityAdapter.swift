import Foundation

/// Adapter for Antigravity (the `agy` CLI and the desktop app), whose stores live in
/// `~/.gemini`. Antigravity has no command to delete or archive a conversation, so in the CLI
/// store (layout verified on 1.5.8) Domovy does it itself, only while Antigravity is quit:
/// files move to the Trash or the quarantine, and its indexes (`conversation_summaries.db`,
/// `cache/conversation_metadata.json`, `history.jsonl`) lose the conversation with a copy kept
/// first, so undo puts them back. The app's own store is assumed, not verified: read-only.
public struct AntigravityAdapter: AgentAdapter {
    public let kind: AgentKind = .antigravity
    /// `~/.gemini`, which holds the stores.
    public let root: URL

    let openHandles: any OpenHandleChecker
    let processes: any RunningProcessLister

    /// Antigravity deletes conversations ranked past this by modification time when it starts.
    public static let conversationCap = 500
    /// Conversations ranked past this are reported as `.expiring`.
    public static let warningRank = 480

    /// Why conversations of the desktop app's store are only read.
    public static let readOnlyReason = "Domovy has not verified the Antigravity app's own store (~/.gemini/antigravity) yet, so it only reads its conversations. The Antigravity CLI's conversations can be deleted and archived."

    /// `agy` is verified (CLI 1.5.8); the app's `Antigravity` and `Antigravity Helper` names are assumed.
    public static let processMatcher = ProcessMatcher(
        appName: "Antigravity", names: ["antigravity"], prefixes: ["antigravity helper"], exactNames: ["agy"],
        quitAdvice: "Quit it to delete or archive this conversation."
    )

    public init(
        geminiHome: URL,
        openHandles: any OpenHandleChecker = LibprocOpenHandleChecker(),
        processes: any RunningProcessLister = LibprocProcessLister()
    ) {
        self.root = geminiHome.standardizedFileURL
        self.openHandles = openHandles
        self.processes = processes
    }

    public init(home: URL) {
        self.init(geminiHome: home.appendingPathComponent(".gemini", isDirectory: true), openHandles: LibprocOpenHandleChecker.shared)
    }

    var stores: [AntigravityStore] { AntigravityStore.stores(in: root) }

    // MARK: AgentAdapter

    /// Ready when the CLI store is there; only the app's (unverified) store is read-only.
    public func status() async -> AdapterStatus {
        let stores = stores
        if stores.isEmpty { return .notInstalled }
        return stores.contains(where: \.isVerified) ? .ready : .readOnly(reason: Self.readOnlyReason)
    }

    public func sessions() async throws -> [Session] {
        let stores = stores
        guard !stores.isEmpty else { throw AdapterError.notInstalled(kind) }
        var listed: [(id: String, store: AntigravityStore, catalog: AntigravityStore.Catalog, index: AntigravityIndex, lastActive: Date, rank: Int)] = []
        for store in stores {
            let index = AntigravityIndex.load(store)
            let catalog = store.catalog()
            let ranked = catalog.ids
                .map { ($0, (catalog.files[$0] ?? []).compactMap(FileSystem.modificationDate).max() ?? .distantPast) }
                .sorted { ($0.1, $0.0) > ($1.1, $1.0) }
            for (rank, (id, lastActive)) in ranked.enumerated() {
                listed.append((id, store, catalog, index, lastActive, rank + 1))
            }
        }
        // One open-file question for the whole listing.
        let holders = await openHandleHolders(of: listed.map { livenessURLs(id: $0.id, store: $0.store, catalog: $0.catalog) }, checker: openHandles)
        return zip(listed, holders).map { item, holders in
            makeSession(id: item.id, store: item.store, catalog: item.catalog, index: item.index, lastActive: item.lastActive,
                        rank: item.rank, live: liveness(id: item.id, store: item.store, holders: holders))
        }
        .sorted { $0.lastActive > $1.lastActive }
    }

    public func artifacts(of session: Session) async throws -> [Artifact] {
        let (store, id) = try locate(session)
        return collectArtifacts(id: id, store: store, catalog: store.catalog())
    }

    public func liveCheck(_ session: Session) async throws -> LiveCheckResult {
        let (store, id) = try locate(session)
        let catalog = store.catalog()
        let holders = await openHandleHolders(of: [livenessURLs(id: id, store: store, catalog: catalog)], checker: openHandles)
        return liveness(id: id, store: store, holders: holders.first ?? nil)
    }

    public func deletePlan(for session: Session, destination: Destination = .trash) async throws -> Plan {
        guard let planned = await deletePlans(for: [session], destination: destination).first else {
            throw AdapterError.sessionNotFound(session.id)
        }
        return try planned.result.get()
    }

    /// A batch lists each store and reads its three indexes once, asks one open-file question
    /// and checks for Antigravity once. The executor checks again right before it changes anything.
    public func deletePlans(for sessions: [Session], destination: Destination) async -> [PlannedSession] {
        var reads: [URL: (catalog: AntigravityStore.Catalog, indexes: AntigravityIndexEdits)] = [:]
        let pending = sessions.map { session in
            Result { () throws -> PendingPlan in
                let (store, id) = try writable(session)
                if reads[store.root] == nil { reads[store.root] = (store.catalog(), AntigravityIndexEdits(store)) }
                guard let read = reads[store.root] else { throw AdapterError.sessionNotFound(session.id) }
                return try deletePlan(id: id, store: store, catalog: read.catalog, indexes: read.indexes, destination: destination)
            }
        }
        return await finish(sessions, pending)
    }

    private func deletePlan(id: String, store: AntigravityStore, catalog: AntigravityStore.Catalog, indexes: AntigravityIndexEdits,
                            destination: Destination) throws -> PendingPlan {
        let files = collectArtifacts(id: id, store: store, catalog: catalog).filter { $0.kind != .indexEntry }
        for file in files where store.isProtected(file.url) { throw AdapterError.protectedPathInPlan(file.url) }
        let moves = files.map { FileMove(source: $0.url, kind: $0.kind, sizeBytes: $0.sizeBytes, note: $0.note) }
        let edits = indexes.edits(id: id)
        var remarks = ["Antigravity has no command to delete a conversation, so Domovy moves its files and takes it out of Antigravity's lists itself, with Antigravity quit. It keeps a copy of each list first, so undo puts them back."]
        remarks += edits.remarks
        let liveFiles = livenessURLs(id: id, store: store, catalog: catalog)
        return PendingPlan(id: id, store: store, files: liveFiles) { check in
            Plan(agent: kind, sessionID: id, action: .delete, destination: destination, moves: moves,
                 indexEdits: [edits.history].compactMap { $0 },
                 databaseEdits: [edits.summaries].compactMap { $0 },
                 jsonRemovals: [edits.metadata].compactMap { $0 },
                 remarks: remarks, mustNotBeRunning: [Self.processMatcher], liveCheck: check, scope: self.scope)
        }
    }

    /// Compresses the conversation's database and brain files in place with APFS compression,
    /// keeping their dates. Antigravity reads them as before; its indexes are left alone.
    public func archivePlan(for session: Session) async throws -> Plan {
        guard let planned = await archivePlans(for: [session]).first else { throw AdapterError.sessionNotFound(session.id) }
        return try planned.result.get()
    }

    public func archivePlans(for sessions: [Session]) async -> [PlannedSession] {
        var catalogs: [URL: AntigravityStore.Catalog] = [:]
        let pending = sessions.map { session in
            Result { () throws -> PendingPlan in
                let (store, id) = try writable(session)
                let catalog = catalogs[store.root] ?? store.catalog()
                catalogs[store.root] = catalog
                return archivePlan(id: id, store: store, catalog: catalog)
            }
        }
        return await finish(sessions, pending)
    }

    private func archivePlan(id: String, store: AntigravityStore, catalog: AntigravityStore.Catalog) -> PendingPlan {
        let databases = (catalog.files[id] ?? []).filter { ["db", "pb"].contains($0.pathExtension.lowercased()) }
        let brain = store.brain.appendingPathComponent(id, isDirectory: true)
        var compressions: [FileCompression] = []
        for file in databases + APFSCompression.regularFiles(at: brain) where !store.isProtected(file) {
            guard APFSCompression.isRegularFile(file), !APFSCompression.isCompressed(file),
                  FileSystem.size(of: file) > APFSCompression.minimumUsefulSize else { continue }
            compressions.append(FileCompression(
                file: file, sizeBytes: APFSCompression.allocatedBytes(of: file),
                estimatedBytes: APFSCompression.estimatedCompressedBytes(of: file),
                modificationTime: FileSystem.modificationTime(of: file),
                note: databases.contains(file) ? "Conversation database" : "Brain file"
            ))
        }
        let remarks = compressions.isEmpty
            ? ["Nothing to compress: the files of this conversation are already compressed or too small to gain from it."]
            : ["Antigravity still opens it. Compression keeps the dates, so it does not change which conversations Antigravity keeps."]
        return PendingPlan(id: id, store: store, files: livenessURLs(id: id, store: store, catalog: catalog)) { check in
            Plan(agent: kind, sessionID: id, action: .archive, destination: nil, moves: [], indexEdits: [],
                 compressions: compressions, remarks: remarks,
                 mustNotBeRunning: compressions.isEmpty ? [] : [Self.processMatcher], liveCheck: check, scope: self.scope)
        }
    }

    /// A plan waiting for its live check.
    private struct PendingPlan {
        let id: String
        let store: AntigravityStore
        let files: [URL]
        let make: (LiveCheckResult) -> Plan
    }

    /// One open-file question for every pending plan and one check for Antigravity, then the
    /// plans in order. While Antigravity runs, every plan counts as live: it writes its lists
    /// and databases, and prunes conversations when it starts.
    private func finish(_ sessions: [Session], _ pending: [Result<PendingPlan, any Error>]) async -> [PlannedSession] {
        let found = pending.compactMap { try? $0.get() }
        let holders = await openHandleHolders(of: found.map(\.files), checker: openHandles)
        let blocking = found.isEmpty ? [] : processes.blockingReasons([Self.processMatcher])
        var next = zip(found, holders).map { item, holders in
            let base = liveness(id: item.id, store: item.store, holders: holders)
            return item.make(LiveCheckResult(isLive: base.isLive || !blocking.isEmpty, reasons: base.reasons + blocking,
                                             checkedSignals: base.checkedSignals + ["Antigravity processes"], openHandles: base.openHandles))
        }.makeIterator()
        return zip(sessions, pending).map { session, pending in
            PlannedSession(session: session, result: pending.flatMap { _ in
                next.next().map { .success($0) } ?? .failure(AdapterError.sessionNotFound(session.id))
            })
        }
    }

    /// The conversation's own format is not verified yet, so there is no preview.
    public func transcript(of session: Session, limit: Int, masking findings: [SecretFinding]) async throws -> Transcript {
        _ = try locate(session)
        return .empty
    }

    // MARK: Sessions

    private func makeSession(id: String, store: AntigravityStore, catalog: AntigravityStore.Catalog, index: AntigravityIndex,
                             lastActive: Date, rank: Int, live: LiveCheckResult) -> Session {
        let artifacts = collectArtifacts(id: id, store: store, catalog: catalog)
        let note: String?
        if rank > Self.conversationCap {
            note = "Antigravity keeps the newest \(Self.conversationCap) conversations; this is number \(rank), so it goes the next time Antigravity starts."
        } else if rank > Self.warningRank {
            let left = Self.conversationCap - rank + 1
            note = "Antigravity keeps the newest \(Self.conversationCap) conversations; this is number \(rank). \(left) more new \(left == 1 ? "conversation pushes" : "conversations push") it out."
        } else {
            note = nil
        }
        let entry = index.entries[id]
        let prompt = catalog.firstPrompts[id]
        let database = catalog.files[id]?.first { $0.pathExtension == "db" || $0.pathExtension == "pb" }
        let archived = database.map(APFSCompression.isCompressed) ?? false
        return Session(
            id: id,
            agent: kind,
            title: entry?.title ?? prompt?.display ?? entry?.preview,
            projectPath: entry?.workspace ?? prompt?.workspace,
            lastActive: lastActive,
            sizeBytes: artifacts.filter { $0.kind != .indexEntry }.reduce(Int64(0)) { $0 + $1.sizeBytes },
            status: live.isLive ? .live : (note != nil ? .expiring : (archived ? .archived : .idle)),
            expiresAt: nil,
            transcriptURL: database ?? store.conversations.appendingPathComponent("\(id).db"),
            isArchived: archived,
            retentionNote: note
        )
    }

    // MARK: Artifacts

    func collectArtifacts(id: String, store: AntigravityStore, catalog: AntigravityStore.Catalog) -> [Artifact] {
        var artifacts: [Artifact] = []
        func add(_ url: URL, _ kind: Artifact.Kind, _ note: String) {
            guard FileSystem.exists(url), !store.isProtected(url) else { return }
            artifacts.append(Artifact(url: url, kind: kind, sizeBytes: FileSystem.size(of: url), note: note))
        }
        for file in (catalog.files[id] ?? []).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            add(file, .file, file.pathExtension == "db" ? "Conversation database" : "Conversation database journal")
        }
        add(store.brain.appendingPathComponent(id, isDirectory: true), .folder, "Brain: plans, walkthroughs, transcripts and tool output")
        add(store.annotations.appendingPathComponent("\(id).pbtxt"), .file, "Annotations")
        add(store.implicit.appendingPathComponent("\(id).pb"), .file, "Implicit memory of this conversation")
        if let n = catalog.historyLines[id], n > 0 {
            artifacts.append(Artifact(url: store.history, kind: .indexEntry, sizeBytes: 0,
                                      note: "\(n) \(n == 1 ? "entry" : "entries") in history.jsonl",
                                      match: IndexMatch(key: "conversationId", value: id)))
        }
        return artifacts
    }

    // MARK: Liveness

    /// The conversation's files and its `presence/<id>.lock`: what a live check asks about.
    private func livenessURLs(id: String, store: AntigravityStore, catalog: AntigravityStore.Catalog) -> [URL] {
        collectArtifacts(id: id, store: store, catalog: catalog).filter { $0.kind != .indexEntry }.map(\.url)
            + [store.presence.appendingPathComponent("\(id).lock")]
    }

    /// Live when the app's `presence/<id>.lock` is held (or present and handles cannot be
    /// checked), or a process has one of the conversation's files open (`holders`: `nil` when
    /// the check could not run).
    private func liveness(id: String, store: AntigravityStore, holders: [OpenHandleHolder]?) -> LiveCheckResult {
        let lock = store.presence.appendingPathComponent("\(id).lock")
        var reasons: [String] = []
        let status: LiveCheckResult.OpenHandleStatus = holders.map { $0.isEmpty ? .clear : .open } ?? .unavailable
        if FileSystem.exists(lock), holders == nil || holders?.contains(where: { $0.path.hasSuffix("/presence/\(id).lock") }) == true {
            reasons.append("Antigravity has this conversation open. Close it in Antigravity first.")
        }
        var seen = Set<Int32>()
        for holder in holders ?? [] where !holder.path.hasSuffix(".lock") && seen.insert(holder.pid).inserted {
            reasons.append("\(holder.processName) (pid \(holder.pid)) has a file of this conversation open.")
        }
        return LiveCheckResult(isLive: !reasons.isEmpty, reasons: reasons, checkedSignals: ["presence/*.lock", "open file handles"], openHandles: status)
    }

    // MARK: Guards

    private func locate(_ session: Session) throws -> (AntigravityStore, String) {
        guard session.agent == kind,
              let store = stores.first(where: { FileSystem.relativePath(of: session.transcriptURL, under: $0.conversations) != nil }),
              store.catalog().files[session.id] != nil else {
            throw AdapterError.sessionNotFound(session.id)
        }
        return (store, session.id)
    }

    /// The conversation's store and id, or why Domovy does not change it.
    private func writable(_ session: Session) throws -> (AntigravityStore, String) {
        let (store, id) = try locate(session)
        guard store.isVerified else { throw AdapterError.readOnly(kind, reason: Self.readOnlyReason) }
        guard SafeID.isSafe(id) else { throw AdapterError.unsafeID(kind, id: id) }
        return (store, id)
    }
}

extension AntigravityAdapter: RetentionReporting {
    public func retentionRule() -> RetentionRule? {
        RetentionRule(
            agent: kind,
            rule: "Antigravity keeps the newest \(Self.conversationCap) conversations.",
            advice: "When it starts, it deletes the older ones by last change, pinned ones too. Archiving in Domovy compresses them but keeps their dates, so it does not save them; copy what you need out of Antigravity before it starts again.",
            settingsFile: nil,
            canArchive: false
        )
    }
}
