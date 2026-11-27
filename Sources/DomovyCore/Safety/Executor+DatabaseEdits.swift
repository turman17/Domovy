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
            // Gone since the plan: there is nothing to edit and nothing to put back. Copies of
            // another database this plan already edited (Zed's two) stay for undo.
            let files = Set(edit.files.map(\.standardizedFileURL))
            for item in entry.snapshots where files.contains(item.original) { if let copy = item.copy { try? fileManager.removeItem(at: copy) } }
            entry.snapshots.removeAll { files.contains($0.original) }
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
}

/// Domovy's own cut of one member out of an app's JSON index (Antigravity's metadata cache):
/// nothing may hold the file open, the file is cloned into the quarantine, the new bytes are
/// written atomically with the old modification time, and undo puts the clone back only while
/// the file is exactly as the edit left it (`restoreSnapshots`).
extension Executor {
    func removeJSONMember(_ removal: JSONMemberRemoval, entry: inout UndoEntry) throws {
        let name = removal.file.lastPathComponent
        guard FileSystem.exists(removal.file) else { return }
        try requireNotOpen([removal.file])
        let data: Data
        do {
            data = try Data(contentsOf: removal.file)
        } catch {
            throw ExecutorError.indexEditFailed(removal.file, reason: error.localizedDescription)
        }
        let found = removal.idField.map { JSONListCut.removing(from: data, field: removal.field.isEmpty ? nil : removal.field, idField: $0, id: removal.key) }
            ?? JSONListCut.removingMember(from: data, field: removal.field, key: removal.key)
        guard let cut = found else {
            throw ExecutorError.indexEditFailed(removal.file, reason: "it has a shape Domovy does not know, so it was left as it is")
        }
        guard cut.removed > 0 else { return }
        try takeSnapshots(of: [removal.file], entry: &entry, failure: "\(name) was not edited") { source, reason in
            ExecutorError.snapshotFailed(source, reason: reason)
        }
        try undoLog.write(entry)
        let modified = FileSystem.modificationTime(of: removal.file)
        let permissions = (try? fileManager.attributesOfItem(atPath: removal.file.path))?[.posixPermissions]
        do {
            try cut.data.write(to: removal.file, options: .atomic)
            if let permissions { try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: removal.file.path) }
            if let modified { try FileSystem.setModificationTime(modified, of: removal.file) }
        } catch {
            settleSnapshots(&entry)
            entry.failure = "\(name) was not edited: \(error.localizedDescription)"
            try undoLog.write(entry)
            throw ExecutorError.indexEditFailed(removal.file, reason: error.localizedDescription)
        }
        Log.executor.info("Removed \(cut.removed, privacy: .public) entries from \(name, privacy: .public)")
        settleSnapshots(&entry)
        try undoLog.write(entry)
    }
}
