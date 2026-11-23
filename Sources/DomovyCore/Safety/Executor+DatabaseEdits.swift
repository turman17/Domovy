import Foundation

/// Domovy's own edit of an app's database (Cursor's `state.vscdb`), the one place it writes to
/// SQLite. In order: nothing may hold the files open, the whole database is cloned into the
/// quarantine, the rows go in one transaction, and `PRAGMA integrity_check` must pass, or the
/// clone goes back at once. Undo puts the clone back only while the file is exactly as the
/// edit left it (`restoreSnapshots`).
extension Executor {
    func editDatabase(_ edit: DatabaseEdit, entry: inout UndoEntry) throws {
        let name = edit.database.lastPathComponent
        try requireNotOpen(edit.files)
        try takeSnapshots(of: edit.files, entry: &entry, failure: "\(name) was not edited") { source, reason in
            ExecutorError.snapshotFailed(source, reason: reason)
        }
        guard entry.snapshots.contains(where: { $0.original == edit.database.standardizedFileURL && $0.copy != nil }) else {
            // Gone since the plan: there is nothing to edit and nothing to put back.
            entry.snapshots = []
            throw ExecutorError.databaseEditFailed(edit.database, reason: "it is no longer there")
        }
        try undoLog.write(entry)

        let outcome: SQLiteWriter.Outcome
        do {
            outcome = try SQLiteWriter.apply(edit)
        } catch {
            // Rolled back: the database is as it was, and an unchanged clone is dropped.
            settleSnapshots(&entry)
            entry.failure = "\(name) was not edited: \(error.localizedDescription)"
            try undoLog.write(entry)
            Log.executor.error("Edit of \(edit.database.path, privacy: .private) failed: \(error.localizedDescription, privacy: .public)")
            throw ExecutorError.databaseEditFailed(edit.database, reason: error.localizedDescription)
        }
        Log.executor.info("Deleted \(outcome.rows, privacy: .public) rows and \(outcome.listEntries, privacy: .public) list entries from \(name, privacy: .public)")

        let problems = integrity.problems(in: edit.database) ?? ["the check could not run"]
        settleSnapshots(&entry)
        guard problems.isEmpty else {
            Log.executor.error("\(name, privacy: .public) failed its integrity check after the edit; restoring the copy")
            do {
                try restoreSnapshots(&entry)
            } catch {
                entry.failure = "\(name) failed its integrity check and its copy could not be put back: \(error.localizedDescription)"
                try undoLog.write(entry)
                throw ExecutorError.integrityCheckFailed(edit.database, problems: problems, restored: false)
            }
            entry.failure = "\(name) failed its integrity check after the edit, so Domovy put its copy back."
            entry.undoneAt = now()
            try undoLog.write(entry)
            throw ExecutorError.integrityCheckFailed(edit.database, problems: problems, restored: true)
        }
        try undoLog.write(entry)
    }

    /// Refuses while any process holds one of `files` open; unsure counts as open.
    func requireNotOpen(_ files: [URL]) throws {
        guard !files.isEmpty else { return }
        guard let holders = processes.holders(of: files) else {
            throw ExecutorError.filesOpen(reasons: ["Domovy could not check which processes have \(files[0].lastPathComponent) open, so it changes nothing."])
        }
        var seen = Set<Int32>()
        let reasons = holders.filter { seen.insert($0.pid).inserted }.map { holder in
            "\(holder.processName) (pid \(holder.pid)) has \(URL(fileURLWithPath: holder.path).lastPathComponent) open. Quit it first."
        }
        guard reasons.isEmpty else { throw ExecutorError.filesOpen(reasons: reasons) }
    }
}
