import Foundation

/// Lines Domovy takes out of a shared index file (`history.jsonl`, `session_index.jsonl`) and
/// puts back on undo. Every rewrite goes through `IndexFileRewrite`, so lines an agent appends
/// meanwhile are never lost.
extension Executor {
    func writeBackup(_ data: Data, of file: URL, entry: UndoEntry, modificationTime: FileTime?) throws -> URL {
        let backupDir = undoLog.backupDirectory(for: entry)
        try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var backup = backupDir.appendingPathComponent(file.lastPathComponent)
        var n = 1
        while FileSystem.exists(backup) {
            backup = backupDir.appendingPathComponent("\(n)-\(file.lastPathComponent)")
            n += 1
        }
        try data.write(to: backup, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        if let modificationTime { try FileSystem.setModificationTime(modificationTime, of: backup) }
        return backup
    }

    /// Backs the index file up and drops the matching lines; mode and mtime stay as they were.
    func removeLines(_ edit: IndexEdit, entry: UndoEntry) throws -> UndoEntry.IndexRestore? {
        var restore: UndoEntry.IndexRestore?
        do {
            try IndexFileRewrite.rewrite(edit.file, hook: indexRewriteHook) { data, mtime in
                // A backup of an earlier attempt is of bytes that changed since.
                if let old = restore { try? fileManager.removeItem(at: old.backup) }
                restore = nil
                var split = JSONLines.split(data)
                // Re-match instead of trusting plan-time line numbers: the agent may have appended since.
                let indices = JSONLines.indices(in: split.lines, where: edit.matchKey, equals: edit.matchValue)
                guard !indices.isEmpty else { return nil }
                let backup = try writeBackup(data, of: edit.file, entry: entry, modificationTime: mtime)
                let removed = indices.map { UndoEntry.RemovedLine(index: $0, bytes: split.lines[$0]) }
                restore = UndoEntry.IndexRestore(file: edit.file, backup: backup, removedLines: removed, modificationTime: mtime)
                for index in indices.reversed() { split.lines.remove(at: index) }
                return split.joined()
            }
        } catch {
            if let old = restore { try? fileManager.removeItem(at: old.backup) }
            throw error
        }
        return restore
    }

    /// Puts removed lines back at their old positions. Lines added since stay, and so does the
    /// file's current modification time. If the file vanished, the backup is restored whole.
    func reinsert(_ restore: UndoEntry.IndexRestore) throws {
        guard FileSystem.itemExists(restore.file) else {
            try fileManager.copyItem(at: restore.backup, to: restore.file)
            if let mtime = restore.modificationTime { try FileSystem.setModificationTime(mtime, of: restore.file) }
            return
        }
        try IndexFileRewrite.rewrite(restore.file, hook: indexRewriteHook) { data, _ in
            var split = JSONLines.split(data)
            for line in restore.removedLines.sorted(by: { $0.index < $1.index }) {
                split.lines.insert(line.bytes, at: min(line.index, split.lines.count))
            }
            if !split.lines.isEmpty { split.trailingNewline = true }
            return split.joined()
        }
    }
}
