import Foundation

/// Adapter for Antigravity (the `agy` CLI and the desktop app), whose stores live in
/// `~/.gemini`. Read-only in this version: Antigravity has no command to delete or archive a
/// conversation, and its conversations are SQLite databases it writes while running (safety
/// rules 3 and 4). Plans say what would change and why nothing does yet.
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

    public static let readOnlyReason = "Antigravity has no command to delete or archive a conversation, and its conversations are SQLite databases it writes while it runs, so Domovy only reads them for now."

    /// `agy` is verified (CLI 1.5.8); the app's `Antigravity` and `Antigravity Helper` names are assumed.
    public static let processMatcher = ProcessMatcher(
        appName: "Antigravity", names: ["antigravity"], prefixes: ["antigravity helper"], exactNames: ["agy"],
        quitAdvice: "Quit Antigravity first."
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
        self.init(geminiHome: home.appendingPathComponent(".gemini", isDirectory: true))
    }

    var stores: [AntigravityStore] { AntigravityStore.stores(in: root) }

    // MARK: AgentAdapter

    public func status() async -> AdapterStatus {
        stores.isEmpty ? .notInstalled : .readOnly(reason: Self.readOnlyReason)
    }

    public func sessions() async throws -> [Session] {
        let stores = stores
        guard !stores.isEmpty else { throw AdapterError.notInstalled(kind) }
        var result: [Session] = []
        for store in stores {
            let index = AntigravityIndex.load(store)
            let catalog = store.catalog()
            let ranked = catalog.ids
                .map { ($0, (catalog.files[$0] ?? []).compactMap(FileSystem.modificationDate).max() ?? .distantPast) }
                .sorted { ($0.1, $0.0) > ($1.1, $1.0) }
            for (rank, (id, lastActive)) in ranked.enumerated() {
                result.append(await makeSession(id: id, store: store, catalog: catalog, index: index, lastActive: lastActive, rank: rank + 1))
            }
        }
        return result.sorted { $0.lastActive > $1.lastActive }
    }

    public func artifacts(of session: Session) async throws -> [Artifact] {
        let (store, id) = try locate(session)
        return collectArtifacts(id: id, store: store, catalog: store.catalog())
    }

    public func liveCheck(_ session: Session) async throws -> LiveCheckResult {
        let (store, id) = try locate(session)
        return await liveness(id: id, store: store, catalog: store.catalog())
    }

    public func deletePlan(for session: Session, destination: Destination = .trash) async throws -> Plan {
        let (store, id) = try locate(session)
        let catalog = store.catalog()
        let files = collectArtifacts(id: id, store: store, catalog: catalog).filter { $0.kind != .indexEntry }
        let bytes = CleanupPlan.bytes(files.reduce(Int64(0)) { $0 + $1.sizeBytes })
        let what = files.map { FileSystem.relativePath(of: $0.url, under: store.root) ?? $0.url.lastPathComponent }.joined(separator: ", ")
        return Plan(agent: kind, sessionID: session.id, action: .delete, destination: destination, moves: [], indexEdits: [],
                    remarks: [
                        "Antigravity is read-only in Domovy for now, so nothing will change. \(Self.readOnlyReason)",
                        "A delete would move \(files.count) \(files.count == 1 ? "item" : "items") (\(bytes)) to \(destination.displayName): \(what).",
                        "Delete it in Antigravity itself if your version offers that.",
                    ],
                    liveCheck: await liveness(id: id, store: store, catalog: catalog), scope: self.scope)
    }

    public func archivePlan(for session: Session) async throws -> Plan {
        let (store, id) = try locate(session)
        return Plan(agent: kind, sessionID: session.id, action: .archive, destination: nil, moves: [], indexEdits: [],
                    remarks: ["Antigravity is read-only in Domovy for now, so nothing will be compressed. \(Self.readOnlyReason)"],
                    liveCheck: await liveness(id: id, store: store, catalog: store.catalog()), scope: self.scope)
    }

    /// The conversation's own format is not verified yet, so there is no preview.
    public func transcript(of session: Session, limit: Int, masking findings: [SecretFinding]) async throws -> Transcript {
        _ = try locate(session)
        return .empty
    }

    // MARK: Sessions

    private func makeSession(id: String, store: AntigravityStore, catalog: AntigravityStore.Catalog, index: AntigravityIndex,
                             lastActive: Date, rank: Int) async -> Session {
        let artifacts = collectArtifacts(id: id, store: store, catalog: catalog)
        let live = await liveness(id: id, store: store, catalog: catalog)
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
        let database = catalog.files[id]?.first { $0.pathExtension == "db" || $0.pathExtension == "pb" }
        return Session(
            id: id,
            agent: kind,
            title: entry?.title,
            projectPath: entry?.workspace,
            lastActive: lastActive,
            sizeBytes: artifacts.filter { $0.kind != .indexEntry }.reduce(Int64(0)) { $0 + $1.sizeBytes },
            status: live.isLive ? .live : (note != nil ? .expiring : .idle),
            expiresAt: nil,
            transcriptURL: database ?? store.conversations.appendingPathComponent("\(id).db"),
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
        if let n = catalog.historyLines[id], n > 0 {
            artifacts.append(Artifact(url: store.history, kind: .indexEntry, sizeBytes: 0,
                                      note: "\(n) \(n == 1 ? "entry" : "entries") in history.jsonl",
                                      match: IndexMatch(key: "conversationId", value: id)))
        }
        return artifacts
    }

    // MARK: Liveness

    /// Live when the app's `presence/<id>.lock` is held (or present and handles cannot be
    /// checked), or a process has one of the conversation's files open.
    private func liveness(id: String, store: AntigravityStore, catalog: AntigravityStore.Catalog) async -> LiveCheckResult {
        let lock = store.presence.appendingPathComponent("\(id).lock")
        let files = collectArtifacts(id: id, store: store, catalog: catalog).filter { $0.kind != .indexEntry }.map(\.url)
        var reasons: [String] = []
        let holders = await openHandles.holders(of: files + [lock])
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
}

extension AntigravityAdapter: RetentionReporting {
    public func retentionRule() -> RetentionRule? {
        RetentionRule(
            agent: kind,
            rule: "Antigravity keeps the newest \(Self.conversationCap) conversations.",
            advice: "When it starts, it deletes the older ones by last change, pinned ones too. Domovy cannot archive them yet; copy what you need out of Antigravity before it starts again.",
            settingsFile: nil,
            canArchive: false
        )
    }
}
