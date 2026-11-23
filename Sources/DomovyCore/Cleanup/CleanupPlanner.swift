import Foundation

/// Plans the Disk screen's guided cleanups (PLAN.md section 4 B). Every cleanup is a `Plan`:
/// files move to the Trash or the quarantine (or, for large rollouts, are compressed in place)
/// and undo puts them back. A plan is blocked while the owning app runs or anything has the
/// files open; when the open-file check cannot run, it is blocked too.
public struct CleanupPlanner: Sendable {
    /// `~/.claude`.
    public let claudeCodeRoot: URL
    /// `~/.codex` or `$CODEX_HOME`.
    public let codexRoot: URL
    /// `~/Library/Application Support/Claude`.
    public let desktopSupport: URL
    /// Ollama, LM Studio and Hugging Face. `nil`: model cleanups report nothing to do.
    public let models: ModelStores?

    let openHandles: any OpenHandleChecker
    let processes: any RunningProcessLister
    let git: GitWorktreeInspector
    /// Which `ollama` and `hf` a model plan may run. Tests and `.devhome` pass stubs.
    let ollamaCLI: ToolChoice
    let huggingFaceCLI: ToolChoice
    /// Domovy's own environment, for `OLLAMA_MODELS`. Tests pass a fixed one.
    let environment: [String: String]
    /// Reads a variable from launchd's user environment (`launchctl getenv`), which the Ollama
    /// app's server inherits. Tests and custom homes answer nothing.
    let launchdEnvironment: @Sendable (String) -> String?
    let now: @Sendable () -> Date

    public init(
        claudeCodeRoot: URL,
        codexRoot: URL,
        desktopSupport: URL,
        models: ModelStores? = nil,
        ollamaCLI: ToolChoice = .none,
        huggingFaceCLI: ToolChoice = .none,
        openHandles: any OpenHandleChecker = LibprocOpenHandleChecker(),
        processes: any RunningProcessLister = LibprocProcessLister(),
        git: GitWorktreeInspector = GitWorktreeInspector(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        launchdEnvironment: @escaping @Sendable (String) -> String? = { _ in nil },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.claudeCodeRoot = claudeCodeRoot.standardizedFileURL
        self.codexRoot = codexRoot.standardizedFileURL
        self.desktopSupport = desktopSupport.standardizedFileURL
        self.models = models
        self.ollamaCLI = ollamaCLI
        self.huggingFaceCLI = huggingFaceCLI
        self.openHandles = openHandles
        self.processes = processes
        self.git = git
        self.environment = environment
        self.launchdEnvironment = launchdEnvironment
        self.now = now
    }

    /// The agents' usual places below a home directory. A custom home (a fixture, `.devhome`)
    /// ignores `OLLAMA_MODELS` and friends and runs only stub CLIs from `<home>/bin`.
    public init(home: URL, isCustomHome: Bool = true, openHandles: any OpenHandleChecker = LibprocOpenHandleChecker(), processes: any RunningProcessLister = LibprocProcessLister()) {
        self.init(
            claudeCodeRoot: home.appendingPathComponent(".claude", isDirectory: true),
            codexRoot: home.appendingPathComponent(".codex", isDirectory: true),
            desktopSupport: home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true),
            models: ModelStores.at(home: home, isCustomHome: isCustomHome),
            ollamaCLI: ToolChoice.at(home: home, isCustomHome: isCustomHome, name: "ollama", override: "DOMOVY_OLLAMA_CLI"),
            huggingFaceCLI: ToolChoice.at(home: home, isCustomHome: isCustomHome, name: "hf", override: "DOMOVY_HF_CLI"),
            openHandles: openHandles,
            processes: processes,
            launchdEnvironment: LaunchdEnvironment.reader(isCustomHome: isCustomHome)
        )
    }

    /// Every folder a cleanup may change; the executor refuses a path outside them.
    var scope: [URL] {
        var folders = [claudeCodeRoot, codexRoot, desktopSupport]
        if let models {
            folders += [models.ollamaHome, models.ollamaModels, models.lmStudioHome, models.huggingFaceHub] + models.lmStudioModels
        }
        return folders
    }

    /// Any process of the Claude desktop app, as in the verified registry matcher.
    static let desktopMatcher = ProcessMatcher(
        appName: "Claude Desktop",
        names: ClaudeDesktopRegistry.processMatcher.names,
        prefixes: ClaudeDesktopRegistry.processMatcher.prefixes,
        exactNames: ClaudeDesktopRegistry.processMatcher.exactNames,
        quitAdvice: "Quit Claude Desktop first; it keeps these files open while it runs."
    )

    var codexMatcher: ProcessMatcher {
        CodexAdapter.processMatcher(codexHome: codexRoot, quitAdvice: "Quit the ChatGPT app or Codex first.")
    }

    public func plan(_ id: CleanupID, destination: Destination = .trash) async throws -> CleanupPlan {
        switch id {
        case .claudeDesktopVM: try await vmBundlePlan(destination: destination)
        case .claudeDesktopCaches: try await desktopCachesPlan(destination: destination)
        case .claudeCodeAgentSDK: try await agentSDKPlan(destination: destination)
        case .codexLogs: try await codexLogsPlan(destination: destination)
        case .codexLargeRollouts: try await largeRolloutsPlan()
        case .codexWorktrees: try await worktreesPlan(.codexWorktrees, folders: codexWorktreeFolders(), destination: destination)
        case .claudeCodeWorktrees: try await worktreesPlan(.claudeCodeWorktrees, folders: claudeCodeWorktreeFolders(), destination: destination)
        case .ollamaOrphanBlobs: try await ollamaOrphansPlan(destination: destination)
        case .huggingFaceDetached: try await detachedRevisionsPlan(destination: destination)
        }
    }

    /// Checks right before running that nothing opened the files since the plan, then executes.
    public func execute(_ cleanup: CleanupPlan, with executor: Executor) async throws -> UndoEntry {
        guard cleanup.canExecute else {
            throw cleanup.isBlocked ? CleanupError.inUse(reasons: cleanup.plan.liveCheck.reasons) : ExecutorError.nothingToDo
        }
        let urls = cleanup.plan.moves.map(\.source) + cleanup.plan.compressions.map(\.file)
        let check = await openFileCheck(urls)
        guard check.reasons.isEmpty else { throw CleanupError.inUse(reasons: check.reasons) }
        return try executor.execute(cleanup.plan)
    }

    // MARK: Shared

    /// Reasons something has these files open, one per process; unsure counts as a reason.
    func openFileCheck(_ urls: [URL]) async -> (reasons: [String], status: LiveCheckResult.OpenHandleStatus, holders: [OpenHandleHolder]) {
        guard !urls.isEmpty else { return ([], .clear, []) }
        guard let holders = await openHandles.holders(of: urls, includingMapped: true) else {
            return (["Domovy could not check which files are open, so it changes nothing."], .unavailable, [])
        }
        var seen = Set<Int32>()
        let reasons = holders.filter { seen.insert($0.pid).inserted }.prefix(3).map {
            "\($0.processName) (pid \($0.pid)) has a file open in \(Self.place(of: $0.path, among: urls))."
        }
        return (Array(reasons), holders.isEmpty ? .clear : .open, holders)
    }

    /// The planned item a kernel path falls in, by name. The kernel reports real paths.
    private static func place(of path: String, among urls: [URL]) -> String {
        let match = urls.first { url in
            var bases = [url.standardizedFileURL.path]
            if let real = realpath(bases[0], nil) {
                bases.append(String(cString: real))
                free(real)
            }
            return bases.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        return match?.lastPathComponent ?? "it"
    }

    /// A plan that moves `items`, blocked by `matchers` and by any open file below them.
    func movePlan(
        _ id: CleanupID,
        items: [(url: URL, note: String)],
        matchers: [ProcessMatcher],
        remarks: [String],
        excluded: [CleanupExclusion] = [],
        hasConsequences: Bool,
        destination: Destination
    ) async -> CleanupPlan {
        let plan = await fileMovePlan(agent: id.agent, label: id.rawValue, items: items, matchers: matchers, remarks: remarks, destination: destination)
        return CleanupPlan(cleanup: id, plan: plan, excluded: excluded, hasConsequences: hasConsequences)
    }

    /// The `Plan` behind `movePlan`, also used by model removals. `label` becomes the plan's
    /// session id, which the undo toast reads.
    func fileMovePlan(
        agent: AgentKind,
        label: String,
        items: [(url: URL, note: String)],
        matchers: [ProcessMatcher],
        remarks: [String],
        extraReasons: [String] = [],
        destination: Destination
    ) async -> Plan {
        let moves = items.map { item in
            FileMove(source: item.url, kind: FileSystem.isDirectory(item.url) ? .folder : .file,
                     sizeBytes: DiskUsage.measure(item.url).allocated, note: item.note)
        }
        let check = await openFileCheck(moves.map(\.source))
        let blocking = processes.blockingReasons(matchers)
        let reasons = extraReasons + blocking + check.reasons
        let liveCheck = LiveCheckResult(
            isLive: !reasons.isEmpty,
            reasons: reasons,
            checkedSignals: ["open file handles"] + matchers.map { "\($0.appName) processes" },
            openHandles: check.status
        )
        return Plan(
            agent: agent,
            sessionID: label,
            action: .delete,
            destination: destination,
            moves: moves,
            indexEdits: [],
            remarks: remarks,
            mustNotBeRunning: matchers,
            liveCheck: liveCheck,
            scope: self.scope
        )
    }

    func requireExisting(_ urls: [URL], _ id: CleanupID) throws -> [URL] {
        let present = urls.filter { FileSystem.exists($0) }
        guard !present.isEmpty else { throw CleanupError.notFound(id) }
        return present
    }
}
