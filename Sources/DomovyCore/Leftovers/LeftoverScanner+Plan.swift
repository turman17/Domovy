import Foundation

/// Plans for leftover worktrees and build output. Every item is checked again right now: git
/// state, live sessions, processes working in it and open files. Whatever no longer qualifies
/// stays, with the reason. Only the selected folders move; their parent folders are the plan's
/// scope, so the executor refuses anything else.
extension LeftoverScanner {
    /// - Parameters:
    ///   - selection: worktree and build output folders from `report`.
    ///   - includingWork: worktrees with work only they hold that the user chose to remove anyway.
    ///     The plan then needs an explicit acknowledgement before it runs.
    public func plan(_ selection: Set<URL>, includingWork: Set<URL> = [], in report: LeftoverReport,
                     sessions: [Session], destination: Destination = .trash) async -> LeftoverPlan {
        let used = usedFolders(sessions)
        let cwd = workingDirectories.workingDirectories()
        var moves: [FileMove] = []
        var excluded: [CleanupExclusion] = []
        var withWork: [URL] = []
        var agents: [AgentKind] = []

        // By path: a URL may or may not carry a trailing slash.
        let selected = Set(selection.map(\.standardizedFileURL.path))
        let withWorkPaths = Set(includingWork.map(\.standardizedFileURL.path))
        let worktrees = report.worktrees.filter { selected.contains($0.url.path) || withWorkPaths.contains($0.url.path) }
        for worktree in worktrees {
            let entry = git.worktrees(of: worktree.url)?.first { Self.real($0.path).path == worktree.url.path }
            guard FileSystem.isDirectory(worktree.url), let entry else {
                excluded.append(CleanupExclusion(url: worktree.url, sizeBytes: worktree.sizeBytes, reason: "git no longer lists it as a worktree. Scan again."))
                continue
            }
            let now = await evaluate(worktree.url, repository: worktree.repository, agent: worktree.agent, locked: entry.isLocked,
                                     branch: entry.branch, used: used, cwd: cwd)
            switch now.state {
            case .leftover(let note):
                moves.append(FileMove(source: now.url, kind: .folder, sizeBytes: now.sizeBytes, note: "\(Self.worktreeNotePrefix) \(note)"))
                if let agent = now.agent { agents.append(agent) }
            case .hasWork(let reason) where withWorkPaths.contains(now.url.path):
                moves.append(FileMove(source: now.url, kind: .folder, sizeBytes: now.sizeBytes, note: "\(Self.worktreeNotePrefix) Has work only it holds: \(reason)"))
                withWork.append(now.url)
                if let agent = now.agent { agents.append(agent) }
            case .hasWork(let reason), .inUse(let reason), .keep(let reason):
                excluded.append(CleanupExclusion(url: now.url, sizeBytes: now.sizeBytes, reason: reason))
            }
        }

        let moving = moves.map(\.source)
        // Build output inside a worktree that moves goes with it.
        let outputs = report.buildOutputs.filter { selected.contains($0.url.path) }
        for output in outputs where !moving.contains(where: { Self.contains($0, output.url) }) {
            guard FileSystem.isDirectory(output.url) else { continue }
            let sessions = used.filter { Self.contains(output.checkout, $0.url) }.map(\.session)
            if let reason = await inUse(output.url, checkout: output.checkout, sessions: sessions, cwd: cwd) {
                excluded.append(CleanupExclusion(url: output.url, sizeBytes: output.sizeBytes, reason: reason))
                continue
            }
            let place = output.isInMainCheckout ? "In the main checkout; reinstall or rebuild before working there again." : "In an agent worktree."
            moves.append(FileMove(source: output.url, kind: .folder, sizeBytes: DiskUsage.measure(output.url).allocated,
                                  note: "Safe: rebuildable. \(output.kind.explanation) \(place)"))
        }

        // Unsure counts as in use: without these checks nothing moves.
        var reasons: [String] = []
        let open = await openHandles.holders(of: moves.map(\.source))
        if cwd == nil { reasons.append("Domovy could not check which processes are working in these folders, so it changes nothing.") }
        if open == nil { reasons.append("Domovy could not check which files are open, so it changes nothing.") }
        let liveCheck = LiveCheckResult(
            isLive: !reasons.isEmpty,
            reasons: reasons,
            checkedSignals: ["live sessions", "process working directories", "open file handles", "git status"],
            openHandles: open == nil ? .unavailable : .clear
        )
        let plan = Plan(
            agent: agents.first ?? .claudeCode,
            sessionID: "leftovers",
            action: .delete,
            destination: destination,
            moves: moves,
            indexEdits: [],
            remarks: remarks(moves),
            acknowledgement: withWork.isEmpty ? nil : Self.workAcknowledgement(withWork.count),
            liveCheck: liveCheck,
            scope: Array(Set(moves.map { $0.source.deletingLastPathComponent() }))
        )
        return LeftoverPlan(plan: plan, excluded: excluded, worktreesWithWork: withWork)
    }

    static func workAcknowledgement(_ count: Int) -> String {
        let what = count == 1 ? "1 worktree holds work" : "\(count) worktrees hold work"
        return "\(what) that exists nowhere else: uncommitted changes, ignored files such as .env, or commits on no branch. It goes to the Trash with the folder. Undo puts it back, but once the Trash is emptied that work is gone."
    }

    private func remarks(_ moves: [FileMove]) -> [String] {
        var remarks: [String] = []
        if moves.contains(where: { $0.note.hasPrefix(Self.worktreeNotePrefix) }) {
            remarks.append("Branches stay in their repositories; only the worktree folders move.")
            remarks.append("git keeps listing a moved worktree until you run `git worktree prune` in its repository (git also does this itself after 3 months). Domovy does not run it, because it cannot be undone.")
        }
        let main = moves.filter { $0.note.contains("In the main checkout") }.count
        if main > 0 {
            remarks.append("\(main) of these \(main == 1 ? "folder is" : "folders are") in a main checkout: run the project's install or build before you work there again.")
        }
        return remarks
    }

    /// Checks again right before running that no process started working in a folder, then
    /// executes; the executor itself checks open files once more.
    public func execute(_ leftover: LeftoverPlan, with executor: Executor) async throws -> UndoEntry {
        guard leftover.canExecute else {
            if leftover.isBlocked { throw CleanupError.inUse(reasons: leftover.plan.liveCheck.reasons) }
            if leftover.plan.needsAcknowledgement, let text = leftover.plan.acknowledgement { throw ExecutorError.needsAcknowledgement(text) }
            throw ExecutorError.nothingToDo
        }
        let sources = leftover.plan.moves.map(\.source)
        guard let holders = workingDirectories.holders(in: sources) else {
            throw CleanupError.inUse(reasons: ["Domovy could not check which processes are working in these folders, so it changes nothing."])
        }
        if !holders.isEmpty {
            var seen = Set<Int32>()
            let reasons = holders.filter { seen.insert($0.pid).inserted }.prefix(3).map { "\($0.processName) (pid \($0.pid)) is working in \(URL(fileURLWithPath: $0.path).lastPathComponent)." }
            throw CleanupError.inUse(reasons: Array(reasons))
        }
        return try executor.execute(leftover.plan)
    }
}
