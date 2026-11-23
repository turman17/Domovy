import Darwin
import Foundation

extension Plan {
    /// Every file or folder the plan moves, rewrites, edits or lets a command delete or rewrite.
    var changedFiles: [URL] {
        moves.map(\.source) + indexEdits.map(\.file) + registryRemovals.map(\.file) + compressions.map(\.file)
            + redactions.map(\.file) + databaseEdits.flatMap { [$0.database] + $0.files }
            + commands.flatMap { $0.copiesBeforeRun + $0.snapshotsBeforeRun + $0.indexLinesBeforeRun.map(\.file) }
    }
}

/// Checks the executor makes right before it acts, whatever the plan says about itself.
extension Executor {
    /// Refuses a plan that names a path outside its scope (the adapter's folders). Ids read from
    /// an agent's data end up in paths; `..` in one must never reach a file elsewhere. Paths are
    /// compared after `..` is resolved, without following symlinks.
    func requireInScope(_ plan: Plan) throws {
        let files = plan.changedFiles
        guard let first = files.first else { return }
        guard !plan.scope.isEmpty else { throw ExecutorError.outsideScope(first) }
        if let outside = files.first(where: { !Self.isInside($0, plan.scope) }) {
            Log.executor.error("Plan \(plan.id, privacy: .public) names \(outside.path, privacy: .private) outside its scope")
            throw ExecutorError.outsideScope(outside)
        }
    }

    /// Undo only moves things back out of Domovy's store or a Trash, and only into the folders
    /// the plan was allowed to change (entries of older versions carry no scope).
    func requireInScope(_ entry: UndoEntry) throws {
        let kept = entry.moved.map(\.current) + entry.registryRestores.map(\.current) + entry.redacted.map(\.original)
        if let stray = kept.first(where: { !Self.isInside($0, [storeRoot]) && !Self.isInTrash($0) }) {
            throw ExecutorError.outsideScope(stray)
        }
        let backups = entry.indexRestores.map(\.backup) + entry.registryRestores.map(\.backup) + entry.snapshots.compactMap(\.copy)
        if let stray = backups.first(where: { !Self.isInside($0, [storeRoot]) }) { throw ExecutorError.outsideScope(stray) }
        guard !entry.scope.isEmpty else { return }
        let originals = entry.moved.map(\.original) + entry.indexRestores.map(\.file) + entry.registryRestores.map(\.file)
            + entry.redacted.map(\.file) + entry.snapshots.map(\.original)
        if let stray = originals.first(where: { !Self.isInside($0, entry.scope) }) { throw ExecutorError.outsideScope(stray) }
    }

    /// Strictly below one of `roots`.
    static func isInside(_ url: URL, _ roots: [URL]) -> Bool {
        roots.contains { root in
            guard let relative = FileSystem.relativePath(of: url, under: root) else { return false }
            return !relative.isEmpty
        }
    }

    /// `~/.Trash/...` or `/Volumes/<disk>/.Trashes/<uid>/...`.
    static func isInTrash(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    /// Refuses while any other process holds one of `files` open; unsure counts as open
    /// (safety rule 2). Domovy's own handles are readers (a preview, a scan), not agents.
    func requireNotOpen(_ files: [URL]) throws {
        guard !files.isEmpty else { return }
        guard let holders = processes.holders(of: files) else {
            throw ExecutorError.filesOpen(reasons: ["Domovy could not check which processes have \(files[0].lastPathComponent) open, so it changes nothing."])
        }
        let me = getpid()
        var seen = Set<Int32>()
        let reasons = holders.filter { $0.pid != me && seen.insert($0.pid).inserted }.map { holder in
            "\(holder.processName) (pid \(holder.pid)) has \(URL(fileURLWithPath: holder.path).lastPathComponent) open. Quit it first."
        }
        guard reasons.isEmpty else { throw ExecutorError.filesOpen(reasons: reasons) }
    }
}
