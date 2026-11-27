import CryptoKit
import Foundation
import os

/// Aider's files, read from Aider-AI/aider@5dc9490b (docs/research/agent_storage_formats.md, Q9; not
/// verified on a real install). Permalink base:
/// https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/
///
/// - Aider has no sessions and no index. In each repository (the git root, else the working
///   folder) it appends to `.aider.chat.history.md` and `.aider.input.history` (aider/args.py#L270-L288);
///   every run starts with `# aider chat started at <time>` (aider/io.py#L336), user prompts are
///   `#### ` lines (io.py#L779-L789) and tool output is quoted with `> ` (io.py#L1117-L1135; prompts end in two spaces).
/// - `.aider.tags.cache.v3/` or `v4/` is a rebuildable cache of the repository map (aider/repomap.py#L35-L43).
/// - `~/.aider/` holds analytics, install records, caches and `oauth-keys.env` (a credential).
/// - `--chat-history-file`, `--input-history-file` and `AIDER_*` variables move the files; Domovy
///   finds only the default names.
struct AiderLayout: Sendable {
    static let chatHistory = ".aider.chat.history.md"
    static let inputHistory = ".aider.input.history"
    static let tagCaches = [".aider.tags.cache.v3", ".aider.tags.cache.v4"]
    static let header = "# aider chat started at"

    /// The only names a plan may move, each directly inside a repository folder.
    static let sessionFiles: Set<String> = Set([chatHistory, inputHistory] + tagCaches)

    struct Repo: Sendable, Hashable {
        let folder: URL
        var history: URL { folder.appendingPathComponent(AiderLayout.chatHistory) }
        var input: URL { folder.appendingPathComponent(AiderLayout.inputHistory) }
        var caches: [URL] { AiderLayout.tagCaches.map { folder.appendingPathComponent($0, isDirectory: true) } }
        /// A stable id from the folder path.
        var id: String {
            "aider-" + SHA256.hash(data: Data(folder.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        }
    }

    static func isProtected(_ url: URL, in repo: Repo) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent() != repo.folder || !sessionFiles.contains(url.lastPathComponent)
    }

    /// The first non-empty line must be Aider's run header; an empty file is fine.
    static func hasKnownLayout(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096), !data.isEmpty else { return true }
        let text = String(decoding: data, as: UTF8.self)
        guard let first = text.split(whereSeparator: \.isNewline).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return true }
        return first.hasPrefix(header)
    }
}

/// Where Domovy looks for Aider's files: the project folders other agents already know, and
/// folders the user names. Never a crawl of the home folder: each candidate, its git root and
/// (for a named search folder) the folders one level below it are checked for the history file.
public struct AiderDiscovery: Sendable {
    /// Absolute project paths known from other agents. Asking them is a full scan, so a scan
    /// that lists them anyway hands its answer over with `use(_:)` instead.
    let known: @Sendable () async -> [String]
    /// Paths read on every lookup (cheap, e.g. Claude Code's project list).
    let extra: @Sendable () -> [String]
    /// Folders the user named; each is checked along with its direct subfolders.
    let searchRoots: [URL]
    private let cache = Cache()
    private let maxAge: TimeInterval

    /// The paths of the last lookup or the ones a scan handed over, shared by every copy.
    /// Concurrent lookups wait for the same task, so they never start a second scan.
    private final class Cache: Sendable {
        struct Entry {
            let task: Task<[String], Never>
            /// `nil` for paths a scan handed over: they stay until the next scan replaces them.
            let date: Date?
        }
        let state = OSAllocatedUnfairLock<Entry?>(initialState: nil)
    }

    public init(known: @escaping @Sendable () async -> [String], extra: @escaping @Sendable () -> [String] = { [] },
                searchRoots: [URL] = [], maxAge: TimeInterval = 30) {
        self.known = known
        self.extra = extra
        self.searchRoots = searchRoots.map(\.standardizedFileURL)
        self.maxAge = maxAge
    }

    /// Uses the project paths of a scan that lists the other agents anyway (in flight or done),
    /// instead of asking them again.
    public func use(_ paths: Task<[String], Never>) {
        cache.state.withLock { $0 = Cache.Entry(task: paths, date: nil) }
    }

    private func knownPaths() async -> [String] {
        let task = cache.state.withLock { entry -> Task<[String], Never> in
            if let entry, entry.date.map({ Date().timeIntervalSince($0) < maxAge }) ?? true { return entry.task }
            let task = Task { await known() }
            entry = Cache.Entry(task: task, date: Date())
            return task
        }
        return await task.value + extra()
    }

    /// Only named folders.
    public static func roots(_ roots: [URL]) -> AiderDiscovery {
        AiderDiscovery(known: { [] }, searchRoots: roots)
    }

    /// The project folders of every session the other adapters list, Claude Code's project list
    /// in `~/.claude.json`, and the search folders the user named: `DOMOVY_AIDER_ROOTS`
    /// (colon-separated) and `agents.aider.searchFolders` in Domovy's settings (read from the
    /// settings file under `home` when `searchFolders` is `nil`).
    public static func standard(home: URL, others: [any AgentAdapter], searchFolders: [String]? = nil,
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> AiderDiscovery {
        let claudeJSON = home.appendingPathComponent(".claude.json")
        let known: @Sendable () async -> [String] = {
            await withTaskGroup(of: [String].self) { group in
                for adapter in others where adapter.kind.hasSessions {
                    group.addTask { ((try? await adapter.sessions()) ?? []).compactMap(\.projectPath) }
                }
                var all: [String] = []
                for await found in group { all += found }
                return all
            }
        }
        let extra: @Sendable () -> [String] = {
            (FileSessions.object(claudeJSON)?["projects"] as? [String: Any]).map { Array($0.keys) } ?? []
        }
        let listed = (environment["DOMOVY_AIDER_ROOTS"] ?? "").split(separator: ":").map(String.init)
        let named = searchFolders ?? SettingsStore.settings(storeRoot: DomovyContext.storeRoot(home: home)).aiderSearchFolders
        let roots = (listed + named).compactMap { DomovySettings.folderURL($0, home: home) }
        return AiderDiscovery(known: known, extra: extra, searchRoots: roots)
    }

    /// Repositories with a chat history file, each once.
    func repos() async -> [AiderLayout.Repo] {
        var candidates: [URL] = []
        // Hundreds of sessions share a few projects: check each folder once.
        var seenPaths = Set<String>()
        for path in await knownPaths() where seenPaths.insert(path).inserted && path.hasPrefix("/") && !path.contains("/../") {
            let folder = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            candidates.append(folder)
            if let git = Self.gitRoot(of: folder), git != folder { candidates.append(git) }
        }
        for root in searchRoots where FileSystem.isDirectory(root) {
            candidates.append(root)
            candidates += FileSystem.children(of: root).filter { FileSystem.isDirectory($0) && !$0.lastPathComponent.hasPrefix(".") }
        }
        var seen = Set<URL>()
        return candidates.compactMap { folder in
            let repo = AiderLayout.Repo(folder: folder.standardizedFileURL)
            guard seen.insert(repo.folder).inserted, FileSystem.exists(repo.history), !FileSystem.isDirectory(repo.history) else { return nil }
            return repo
        }
    }

    /// The nearest folder at or above `folder` holding `.git`, at most 8 levels up.
    static func gitRoot(of folder: URL) -> URL? {
        var current = folder
        for _ in 0..<8 {
            if FileSystem.exists(current.appendingPathComponent(".git")) { return current }
            let parent = current.deletingLastPathComponent()
            if parent == current || parent.path == "/" { return nil }
            current = parent
        }
        return nil
    }
}

/// Adapter for Aider. A "session" is one repository's chat history with its input history and
/// tag caches. Aider has no delete or archive of its own (`/clear` only empties the running
/// chat), so with Aider quit Domovy moves those files to the Trash or the quarantine, or
/// compresses the two history files in place for an archive.
public struct AiderAdapter: AgentAdapter {
    public let kind: AgentKind = .aider
    /// `~/.aider`.
    public let root: URL

    let discovery: AiderDiscovery
    let openHandles: any OpenHandleChecker
    let processes: any RunningProcessLister

    /// `aider` is a Python entry point (`aider-chat`, pyproject.toml `aider = "aider.main:main"`).
    public static let processMatcher = ProcessMatcher(
        appName: "Aider", names: ["aider"], quitAdvice: "Quit Aider to change its chat history.",
        argumentMarkers: ["/bin/aider", "aider.main", "aider-chat"]
    )

    public init(aiderHome: URL, discovery: AiderDiscovery, openHandles: any OpenHandleChecker = LibprocOpenHandleChecker(),
                processes: any RunningProcessLister = LibprocProcessLister()) {
        self.root = aiderHome.standardizedFileURL
        self.discovery = discovery
        self.openHandles = openHandles
        self.processes = processes
    }

    public init(home: URL, discovery: AiderDiscovery) {
        self.init(aiderHome: home.appendingPathComponent(".aider", isDirectory: true), discovery: discovery, openHandles: LibprocOpenHandleChecker.shared)
    }

    /// Hands over the project paths of a scan of the other adapters, in flight or done, so
    /// Aider does not list every other agent again.
    public func useKnownProjects(_ paths: Task<[String], Never>) {
        discovery.use(paths)
    }

    // MARK: AgentAdapter

    public func status() async -> AdapterStatus {
        status(of: await discovery.repos())
    }

    private func status(of repos: [AiderLayout.Repo]) -> AdapterStatus {
        guard !repos.isEmpty || FileSystem.isDirectory(root) else { return .notInstalled }
        if let odd = repos.first(where: { !AiderLayout.hasKnownLayout($0.history) }) {
            return .readOnly(reason: "The chat history in \(odd.folder.lastPathComponent) does not start with \"\(AiderLayout.header)\", the layout Domovy knows from Aider, so it only lists what it can read.")
        }
        return .ready
    }

    public func sessions() async throws -> [Session] {
        let repos = await discovery.repos()
        if case .notInstalled = status(of: repos) { throw AdapterError.notInstalled(kind) }
        let holders = await openHandleHolders(of: repos.map(files(of:)), checker: openHandles)
        return zip(repos, holders).map { repo, holders in
            makeSession(repo, live: FileSessions.liveness(markers: [], holders: holders, signals: []))
        }
        .sorted { $0.lastActive > $1.lastActive }
    }

    public func artifacts(of session: Session) async throws -> [Artifact] {
        collectArtifacts(try locate(session))
    }

    public func liveCheck(_ session: Session) async throws -> LiveCheckResult {
        let repo = try locate(session)
        return FileSessions.liveness(markers: [], holders: await openHandles.holders(of: files(of: repo)), signals: [])
    }

    public func deletePlan(for session: Session, destination: Destination = .trash) async throws -> Plan {
        let repo = try locate(session)
        try await requireWritable()
        let live = FileSessions.forPlan(try await liveCheck(session), blocking: processes.blockingReasons([Self.processMatcher]), app: "Aider")
        let artifacts = collectArtifacts(repo)
        for artifact in artifacts where AiderLayout.isProtected(artifact.url, in: repo) { throw AdapterError.protectedPathInPlan(artifact.url) }
        let moves = artifacts.map { FileMove(source: $0.url, kind: $0.kind, sizeBytes: $0.sizeBytes, note: $0.note) }
        return Plan(agent: kind, sessionID: session.id, action: .delete, destination: destination, moves: moves, indexEdits: [],
                    remarks: [
                        "Aider keeps one chat history per repository and has no command to delete it, so Domovy moves these files itself while Aider is quit. Aider starts a new history the next time it runs here.",
                        "Only these files move; the repository and everything else in it stay as they are.",
                    ],
                    mustNotBeRunning: [Self.processMatcher], liveCheck: live, scope: [repo.folder])
    }

    /// Compresses the chat and input history in place; Aider appends to them unchanged.
    public func archivePlan(for session: Session) async throws -> Plan {
        let repo = try locate(session)
        try await requireWritable()
        let live = FileSessions.forPlan(try await liveCheck(session), blocking: processes.blockingReasons([Self.processMatcher]), app: "Aider")
        let histories = collectArtifacts(repo).filter { $0.kind == .file }
        let compressions = try FileSessions.compressions(of: histories) { AiderLayout.isProtected($0, in: repo) }
        return Plan(agent: kind, sessionID: session.id, action: .archive, destination: nil, moves: [], indexEdits: [],
                    compressions: compressions,
                    remarks: ["Aider has no archive. Domovy compresses the history files in place; Aider still reads and appends to them."],
                    mustNotBeRunning: [Self.processMatcher], liveCheck: live, scope: [repo.folder])
    }

    /// `#### ` lines are prompts; the text up to the next prompt or run header is the reply,
    /// without the `> ` lines of Aider's own output. Masked line by line; content is never logged.
    public func transcript(of session: Session, limit: Int, masking findings: [SecretFinding]) async throws -> Transcript {
        let repo = try locate(session)
        let mask = TranscriptMask(findings: findings, file: repo.history)
        let maxBytes = 4 * 1024 * 1024
        guard let handle = try? FileHandle(forReadingFrom: repo.history) else { throw AdapterError.unreadable(repo.history, reason: "it could not be opened") }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes + 1)) ?? Data()
        var truncated = data.count > maxBytes
        var messages: [TranscriptMessage] = []
        var hidden = 0
        var reply: [String] = []
        func flushReply() {
            let text = reply.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            reply = []
            guard !text.isEmpty, !messages.isEmpty else { return }
            messages.append(TranscriptMessage(id: "a\(messages.count)", role: .assistant, timestamp: nil, blocks: [.text(text)]))
        }
        var offset = 0
        for raw in data.prefix(maxBytes).split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            defer { offset += raw.count + 1 }
            guard let masked = mask.apply(Data(raw), at: Int64(offset)) else {
                hidden += 1
                continue
            }
            let line = String(decoding: masked, as: UTF8.self)
            if line.hasPrefix("#### ") {
                flushReply()
                if messages.count >= limit {
                    truncated = true
                    break
                }
                messages.append(TranscriptMessage(id: "u\(messages.count)", role: .user, timestamp: nil, blocks: [.text(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))]))
            } else if line.hasPrefix(AiderLayout.header) {
                flushReply()
            } else if !line.hasPrefix(">") {
                reply.append(line)
            }
        }
        if messages.count < limit { flushReply() }
        return Transcript(messages: Array(messages.prefix(max(0, limit))), isTruncated: truncated, hiddenLineCount: hidden)
    }

    // MARK: Sessions

    private func makeSession(_ repo: AiderLayout.Repo, live: LiveCheckResult) -> Session {
        let compressed = APFSCompression.isCompressed(repo.history)
        return Session(
            id: repo.id,
            agent: kind,
            title: firstPrompt(repo.history) ?? "Aider chat in \(repo.folder.lastPathComponent)",
            projectPath: repo.folder.path,
            lastActive: FileSystem.modificationDate(of: repo.history) ?? .distantPast,
            sizeBytes: collectArtifacts(repo).reduce(0) { $0 + $1.sizeBytes },
            status: live.isLive ? .live : compressed ? .archived : .idle,
            expiresAt: nil,
            transcriptURL: repo.history,
            isArchived: compressed
        )
    }

    private func firstPrompt(_ file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024) else { return nil }
        let line = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first { $0.hasPrefix("#### ") }
        return FileSessions.title(line.map { String($0.dropFirst(5)) })
    }

    func collectArtifacts(_ repo: AiderLayout.Repo) -> [Artifact] {
        var artifacts = [Artifact(url: repo.history, kind: .file, sizeBytes: FileSystem.size(of: repo.history), note: "Chat history")]
        if FileSystem.exists(repo.input), !FileSystem.isDirectory(repo.input) {
            artifacts.append(Artifact(url: repo.input, kind: .file, sizeBytes: FileSystem.size(of: repo.input), note: "Prompt history (up-arrow recall)"))
        }
        for cache in repo.caches where FileSystem.isDirectory(cache) {
            artifacts.append(Artifact(url: cache, kind: .folder, sizeBytes: FileSystem.size(of: cache), note: "Repository map cache; Aider rebuilds it"))
        }
        return artifacts
    }

    private func files(of repo: AiderLayout.Repo) -> [URL] {
        collectArtifacts(repo).map(\.url)
    }

    // MARK: Guards

    private func locate(_ session: Session) throws -> AiderLayout.Repo {
        let file = session.transcriptURL.standardizedFileURL
        let repo = AiderLayout.Repo(folder: file.deletingLastPathComponent())
        guard session.agent == kind, file.lastPathComponent == AiderLayout.chatHistory, repo.id == session.id,
              FileSystem.exists(file), !FileSystem.isDirectory(file) else {
            throw AdapterError.sessionNotFound(session.id)
        }
        return repo
    }

    private func requireWritable() async throws {
        switch await status() {
        case .readOnly(let reason): throw AdapterError.readOnly(kind, reason: reason)
        case .notInstalled: throw AdapterError.notInstalled(kind)
        case .ready: break
        }
    }
}

extension AiderAdapter {
    public func footprint() async throws -> Footprint {
        let repos = await discovery.repos()
        guard !repos.isEmpty || FileSystem.isDirectory(root) else { throw AdapterError.notInstalled(kind) }
        var builder = FootprintBuilder(agent: kind, root: root)
        builder.add("Chat histories", repos.flatMap { [$0.history, $0.input] }, reveal: repos.first?.folder ?? root, .consequences,
                    "\(repos.count) \(repos.count == 1 ? "repository" : "repositories") Domovy knows from other agents or your search folders. Delete or archive them in Sessions.",
                    guidance: .manageInSessions)
        builder.add("Repository map caches", repos.flatMap(\.caches), reveal: repos.first?.folder ?? root, .safe,
                    "Aider rebuilds these caches of each repository's map. They go with the chat history in Sessions.", guidance: .manageInSessions)
        builder.add("Sign-in", root.appendingPathComponent("oauth-keys.env"), .keep, "Aider's saved API keys. Domovy never removes them.")
        builder.add("Caches and records", builder.unclaimedChildren(of: root), reveal: root, .keep,
                    "Analytics settings, install records and caches in ~/.aider. Left alone.")
        return builder.build()
    }
}
