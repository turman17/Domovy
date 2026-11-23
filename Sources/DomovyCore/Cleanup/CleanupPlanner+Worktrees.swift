import Foundation

/// Agent worktrees: a folder moves to the Trash only when git says it is clean and its commits
/// are on another branch. Everything else stays, with the reason. Domovy never runs
/// `git worktree remove` or `git worktree prune`.
extension CleanupPlanner {
    /// `worktrees/<id>/<repo>` in CODEX_HOME. Anything else in there is reported, never moved.
    func codexWorktreeFolders() -> (worktrees: [URL], other: [URL]) {
        var worktrees: [URL] = []
        var other: [URL] = []
        for group in FileSystem.children(of: CodexLayout(root: codexRoot).worktrees) {
            guard FileSystem.isDirectory(group) else { other.append(group); continue }
            let repos = FileSystem.children(of: group)
            if repos.isEmpty { other.append(group) }
            for repo in repos {
                if FileSystem.isDirectory(repo), GitWorktreeInspector.isLinkedWorktree(repo) { worktrees.append(repo) } else { other.append(repo) }
            }
        }
        return (worktrees, other)
    }

    /// `~/.claude/worktrees/<name>`, when Claude Code keeps worktrees there.
    func claudeCodeWorktreeFolders() -> (worktrees: [URL], other: [URL]) {
        let children = FileSystem.children(of: ClaudeCodeLayout(root: claudeCodeRoot).worktrees)
        let worktrees = children.filter { FileSystem.isDirectory($0) && GitWorktreeInspector.isLinkedWorktree($0) }
        return (worktrees, children.filter { !worktrees.contains($0) })
    }

    func worktreesPlan(_ id: CleanupID, folders: (worktrees: [URL], other: [URL]), destination: Destination) async throws -> CleanupPlan {
        guard !folders.worktrees.isEmpty || !folders.other.isEmpty else { throw CleanupError.notFound(id) }
        var excluded = folders.other.map {
            CleanupExclusion(url: $0, sizeBytes: DiskUsage.measure($0).allocated, reason: "Not a git worktree Domovy recognises. Left alone.")
        }
        var items: [(url: URL, note: String)] = []
        let open = await openFileCheck(folders.worktrees)
        for worktree in folders.worktrees {
            let size = DiskUsage.measure(worktree).allocated
            if let holder = open.holders.first(where: { !matchOpenPaths([$0], against: [worktree]).isEmpty }) {
                excluded.append(CleanupExclusion(url: worktree, sizeBytes: size, reason: "In use: \(holder.processName) (pid \(holder.pid)) has a file open in it."))
                continue
            }
            switch git.inspect(worktree) {
            case .removable(let note): items.append((worktree, note))
            case .keep(let reason): excluded.append(CleanupExclusion(url: worktree, sizeBytes: size, reason: reason))
            }
        }
        let remarks = [
            "Only clean worktrees whose commits are on another branch move. Their branches stay in the main repository.",
            "Git keeps listing a moved worktree until you run `git worktree prune` in its main repository. Domovy does not run it, because it would also forget other missing worktrees.",
        ]
        // Codex may be working in one of its worktrees without holding a file open.
        let matchers = id == .codexWorktrees ? [codexMatcher] : []
        return await movePlan(id, items: items, matchers: matchers, remarks: remarks, excluded: excluded, hasConsequences: true, destination: destination)
    }
}
