import Foundation

/// Finds agent worktrees and build output left in the projects agents worked in, and plans
/// their removal (the Disk screen's "Leftover checkouts and build output").
///
/// Repositories come from the sessions' project folders and from the agents' own worktree
/// folders (`~/.claude/worktrees`, `<repo>/.claude/worktrees`, `~/.codex/worktrees`,
/// `~/.cursor/worktrees`, Herdr's `~/.herdr/worktrees`); the home folder is never crawled. Git
/// is only read. A worktree is a leftover when nothing uses it, it has no uncommitted or ignored work, and its commits are on a
/// branch; removing the folder keeps the branch. Everything moves to the Trash or the
/// quarantine, so undo puts it back.
public struct LeftoverScanner: Sendable {
    public let home: URL
    public let claudeCodeRoot: URL
    public let codexRoot: URL
    public let cursorRoot: URL
    let git: GitReader
    let openHandles: any OpenHandleChecker
    let workingDirectories: any WorkingDirectoryLister

    /// Every worktree move's note starts with this, so a plan can tell worktrees from build output.
    static let worktreeNotePrefix = "Agent worktree."
    /// Session project folders looked at, at most.
    static let maxProjects = 300

    public init(
        home: URL,
        claudeCodeRoot: URL? = nil,
        codexRoot: URL? = nil,
        cursorRoot: URL? = nil,
        git: GitReader = GitReader(),
        openHandles: any OpenHandleChecker = LibprocOpenHandleChecker.shared,
        workingDirectories: any WorkingDirectoryLister = LibprocWorkingDirectoryLister()
    ) {
        self.home = Self.real(home)
        self.claudeCodeRoot = Self.real(claudeCodeRoot ?? home.appendingPathComponent(".claude", isDirectory: true))
        self.codexRoot = Self.real(codexRoot ?? home.appendingPathComponent(".codex", isDirectory: true))
        self.cursorRoot = Self.real(cursorRoot ?? home.appendingPathComponent(".cursor", isDirectory: true))
        self.git = git
        self.openHandles = openHandles
        self.workingDirectories = workingDirectories
    }

    // MARK: Scan

    public func scan(sessions: [Session]) async -> LeftoverReport {
        let used = usedFolders(sessions)
        let projects = projectFolders(sessions)
        var repositories: [URL: [GitReader.WorktreeEntry]] = [:]
        var known = Set<URL>()
        var unreadable: [URL] = []
        var plain: [URL] = []

        func learn(_ folder: URL) -> Bool {
            guard let entries = git.worktrees(of: folder), let main = entries.first else { return false }
            let normalized = entries.map { GitReader.WorktreeEntry(path: Self.real($0.path), branch: $0.branch, isBare: $0.isBare, isLocked: $0.isLocked, isPrunable: $0.isPrunable) }
            repositories[Self.real(main.path)] = normalized
            known.formUnion(normalized.map(\.path))
            return true
        }
        func isKnown(_ folder: URL) -> Bool { known.contains { Self.contains($0, folder) } }

        for project in projects where !isKnown(project) {
            if !learn(project) { plain.append(project) }
        }
        for folder in agentWorktreeFolders(mains: Array(repositories.keys)) where !isKnown(folder) {
            if !learn(folder) { unreadable.append(folder) }
        }

        let cwd = workingDirectories.workingDirectories()
        var groups: [LeftoverGroup] = []
        for (main, entries) in repositories {
            var worktrees: [AgentWorktree] = []
            var outputs: [BuildOutput] = []
            let linked = entries.dropFirst().filter { !$0.isPrunable && !$0.isBare && FileSystem.isDirectory($0.path) }
            let registered = Set(linked.map(\.path))
            // A folder in `<repo>/.claude/worktrees` that git does not list is reported, never moved.
            let stray = FileSystem.children(of: main.appendingPathComponent(".claude/worktrees")).map(Self.real)
                .filter { FileSystem.isDirectory($0) && !registered.contains($0) && GitWorktreeInspector.isLinkedWorktree($0) }
            for entry in linked {
                guard let agent = owner(of: entry.path, used: used) else { continue }
                let worktree = await evaluate(entry.path, repository: main, agent: agent, locked: entry.isLocked, branch: entry.branch, used: used, cwd: cwd)
                worktrees.append(worktree)
                if !worktree.isLeftover {
                    outputs += await buildOutputs(in: entry.path, isGit: true, isMain: false, used: used, cwd: cwd)
                }
            }
            for folder in stray {
                worktrees.append(keep(folder, repository: main, agent: .claudeCode, reason: "git does not list it as a worktree of this repository, so Domovy leaves it alone.", used: used))
            }
            // The main checkout's build output, when an agent worked there (not only in a worktree).
            if projects.contains(where: { project in Self.contains(main, project) && !linked.contains { Self.contains($0.path, project) } }), main != home, entries.first?.isBare != true {
                outputs += await buildOutputs(in: main, isGit: true, isMain: true, used: used, cwd: cwd)
            }
            guard !worktrees.isEmpty || !outputs.isEmpty else { continue }
            groups.append(LeftoverGroup(root: main, worktrees: worktrees.sorted { $0.sizeBytes > $1.sizeBytes }, buildOutputs: outputs.sorted { $0.sizeBytes > $1.sizeBytes }))
        }
        for folder in plain {
            let outputs = await buildOutputs(in: folder, isGit: false, isMain: true, used: used, cwd: cwd)
            guard !outputs.isEmpty else { continue }
            groups.append(LeftoverGroup(root: folder, worktrees: [], buildOutputs: outputs.sorted { $0.sizeBytes > $1.sizeBytes }))
        }
        if !unreadable.isEmpty {
            let worktrees = unreadable.map {
                keep($0, repository: nil, agent: owner(of: $0, used: used), reason: "git could not read it; its main repository may be gone. Kept in case it holds the only copy of some work.", used: used)
            }
            groups.append(LeftoverGroup(root: unreadable[0].deletingLastPathComponent(), worktrees: worktrees, buildOutputs: []))
        }
        return LeftoverReport(groups: groups.sorted { ($0.reclaimableBytes, $0.name) > ($1.reclaimableBytes, $1.name) })
    }

    /// The agent a linked worktree belongs to: by the folder it is in, or by the sessions that ran
    /// in it. `nil` for a worktree no agent touched, which is the user's own and not listed.
    func owner(of folder: URL, used: [(url: URL, session: Session)]) -> AgentKind? {
        if folder.pathComponents.joined(separator: "/").contains(".claude/worktrees/") || Self.contains(claudeCodeRoot.appendingPathComponent("worktrees"), folder) {
            return .claudeCode
        }
        if Self.contains(codexRoot.appendingPathComponent("worktrees"), folder) { return .codex }
        if Self.contains(cursorRoot.appendingPathComponent("worktrees"), folder) { return .cursor }
        if Self.contains(herdrWorktrees, folder) { return .herdr }
        return used.first { Self.contains(folder, $0.url) }?.session.agent
    }

    /// Linked worktrees in the agents' own folders, one or two levels down.
    var herdrWorktrees: URL { Self.real(HerdrWorktrees.folder(home: home)) }

    func agentWorktreeFolders(mains: [URL]) -> [URL] {
        var candidates = FileSystem.children(of: claudeCodeRoot.appendingPathComponent("worktrees"))
        for main in mains { candidates += FileSystem.children(of: main.appendingPathComponent(".claude/worktrees")) }
        // Herdr's `<directory>/<repo>/<branch>`; a pane working in one keeps it, like any process's cwd.
        for folder in [codexRoot, cursorRoot].map({ $0.appendingPathComponent("worktrees") }) + [herdrWorktrees] {
            for child in FileSystem.children(of: folder) {
                candidates += GitWorktreeInspector.isLinkedWorktree(child) ? [child] : FileSystem.children(of: child)
            }
        }
        return candidates.map(Self.real).filter { FileSystem.isDirectory($0) && GitWorktreeInspector.isLinkedWorktree($0) }
    }

    /// Distinct, existing project folders of the sessions, never the home folder, an ancestor of
    /// it, or anything inside an agent's own storage or `~/Library`.
    func projectFolders(_ sessions: [Session]) -> [URL] {
        var seen = Set<URL>()
        var result: [URL] = []
        let excluded = [claudeCodeRoot, codexRoot, cursorRoot, home.appendingPathComponent("Library")]
        for path in sessions.lazy.compactMap(\.projectPath) where result.count < Self.maxProjects {
            let url = Self.real(URL(fileURLWithPath: path, isDirectory: true))
            guard seen.insert(url).inserted, url.pathComponents.count > 2, !Self.contains(url, home),
                  !excluded.contains(where: { Self.contains($0, url) }), !url.pathComponents.contains(".Trash"),
                  FileSystem.isDirectory(url) else { continue }
            result.append(url)
        }
        return result
    }

    func usedFolders(_ sessions: [Session]) -> [(url: URL, session: Session)] {
        sessions.compactMap { session in
            session.projectPath.map { (Self.real(URL(fileURLWithPath: $0, isDirectory: true)), session) }
        }
    }

    // MARK: Evaluation

    /// The worktree's state right now: in use first, then what git says.
    func evaluate(_ url: URL, repository: URL?, agent: AgentKind?, locked: Bool, branch: String?,
                  used: [(url: URL, session: Session)], cwd: [OpenHandleHolder]?) async -> AgentWorktree {
        let sessions = used.filter { Self.contains(url, $0.url) }.map(\.session)
        let state: AgentWorktree.State
        if let reason = await inUse(url, checkout: url, sessions: sessions, cwd: cwd) {
            state = .inUse(reason)
        } else if locked {
            state = .keep("Locked with git worktree lock, so Domovy leaves it alone.")
        } else if let inspection = git.inspect(url) {
            state = Self.state(from: inspection)
        } else {
            state = .keep("git could not read it; its main repository may be gone. Kept in case it holds the only copy of some work.")
        }
        return AgentWorktree(url: url, repository: repository, agent: agent, branch: branch, sizeBytes: DiskUsage.measure(url).allocated,
                             state: state, sessionCount: sessions.count, lastActive: sessions.map(\.lastActive).max())
    }

    static func state(from inspection: GitReader.Inspection) -> AgentWorktree.State {
        if !inspection.changes.isEmpty {
            let n = inspection.changes.count
            return .hasWork("\(n) uncommitted \(n == 1 ? "change" : "changes") (\(list(inspection.changes))). They exist only in this folder.")
        }
        if !inspection.ignoredKept.isEmpty {
            let files = inspection.ignoredKept
            return .hasWork("Holds \(list(files)), which git ignores, so no commit keeps \(files.count == 1 ? "it" : "them").")
        }
        guard inspection.commitsOnABranch else {
            return .hasWork("Its commits are on no branch; removing the folder would leave them only in git's reflog.")
        }
        if let branch = inspection.branch {
            let merged = inspection.mergedInto.map { "merged into \($0)" } ?? "not merged yet"
            return .leftover("Clean. Branch \(branch) (\(merged)) stays in the repository.")
        }
        return .leftover("Clean; its commit is on \(inspection.mergedInto ?? "another branch").")
    }

    private static func list(_ paths: [String]) -> String {
        let shown = paths.prefix(3).joined(separator: ", ")
        return paths.count > 3 ? "\(shown) and \(paths.count - 3) more" : shown
    }

    /// Why nothing in `checkout` may change now, or `nil`. `url` is what would move.
    func inUse(_ url: URL, checkout: URL, sessions: [Session], cwd: [OpenHandleHolder]?) async -> String? {
        if let live = sessions.first(where: { $0.status == .live }) {
            return "A \(live.agent.displayName) session is live here."
        }
        guard let cwd else { return "Domovy could not check which processes are working here, so it leaves it alone." }
        if let holder = matchOpenPaths(cwd, against: [checkout]).first {
            return "\(holder.processName) (pid \(holder.pid)) is working in \(checkout.lastPathComponent)."
        }
        guard let open = await openHandles.holders(of: [url]) else {
            return "Domovy could not check which files are open, so it leaves it alone."
        }
        if let holder = open.first {
            return "\(holder.processName) (pid \(holder.pid)) has a file open in it."
        }
        return nil
    }

    func buildOutputs(in checkout: URL, isGit: Bool, isMain: Bool, used: [(url: URL, session: Session)], cwd: [OpenHandleHolder]?) async -> [BuildOutput] {
        let sessions = used.filter { Self.contains(checkout, $0.url) }.map(\.session)
        var result: [BuildOutput] = []
        for (url, kind) in BuildOutputFinder(git: git).find(in: checkout, isGit: isGit) {
            let reason = await inUse(url, checkout: checkout, sessions: sessions, cwd: cwd)
            result.append(BuildOutput(url: url, kind: kind, sizeBytes: DiskUsage.measure(url).allocated, checkout: checkout, isInMainCheckout: isMain, inUse: reason))
        }
        return result
    }

    private func keep(_ url: URL, repository: URL?, agent: AgentKind?, reason: String, used: [(url: URL, session: Session)]) -> AgentWorktree {
        let sessions = used.filter { Self.contains(url, $0.url) }.map(\.session)
        return AgentWorktree(url: url, repository: repository, agent: agent, branch: nil, sizeBytes: DiskUsage.measure(url).allocated,
                             state: .keep(reason), sessionCount: sessions.count, lastActive: sessions.map(\.lastActive).max())
    }

    // MARK: Paths

    /// Git reports real paths (`/private/var/...`) and sessions may name a folder through a
    /// symlink. Both are resolved, then standardized the way every other Domovy URL is, so plan
    /// scopes and undo entries compare equal.
    static func real(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        guard let resolved = realpath(path, nil) else { return url.standardizedFileURL }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true).standardizedFileURL
    }

    /// `url` is `folder` or below it.
    static func contains(_ folder: URL, _ url: URL) -> Bool {
        FileSystem.relativePath(of: url, under: folder) != nil
    }
}
