import Foundation

public enum ExecutorError: Error, LocalizedError, Sendable {
    case sessionIsLive(reasons: [String])
    case nothingToDo
    case moveFailed(URL, reason: String, movedSoFar: Int, total: Int)
    case indexEditFailed(URL, reason: String)
    case restoreFailed(URL, reason: String)
    case compressionFailed(URL, reason: String, doneSoFar: Int, total: Int)
    case alreadyUndone
    case nothingToUndo

    public var errorDescription: String? {
        switch self {
        case .sessionIsLive(let reasons):
            "This session is live, so nothing was changed. " + reasons.joined(separator: " ")
        case .nothingToDo:
            "Nothing to do: the plan is empty."
        case .moveFailed(let url, let reason, let moved, let total):
            "Could not move \(url.lastPathComponent): \(reason). \(moved) of \(total) items were moved; run undo to put them back."
        case .indexEditFailed(let url, let reason):
            "Could not edit \(url.lastPathComponent): \(reason). Files already moved can be restored with undo."
        case .compressionFailed(let url, let reason, let done, let total):
            "Could not compress \(url.lastPathComponent): \(reason) \(done) of \(total) files were compressed; run undo to decompress them."
        case .restoreFailed(let url, let reason):
            "Could not restore \(url.lastPathComponent): \(reason)"
        case .alreadyUndone:
            "This action was already undone."
        case .nothingToUndo:
            "There is nothing to undo."
        }
    }
}

/// Executes a `Plan` reversibly and undoes it later. Files go to the Trash or to a
/// quarantine folder under `storeRoot`; every run writes an undo entry first thing.
public struct Executor: Sendable {
    public let storeRoot: URL
    public let undoLog: UndoLog
    let now: @Sendable () -> Date
    var fileManager: FileManager { .default }

    public var quarantineDirectory: URL { storeRoot.appendingPathComponent("Quarantine", isDirectory: true) }

    /// - Parameter storeRoot: Domovy's own folder (app: `~/Library/Application Support/Domovy`;
    ///   tests: a temp dir). Never a folder inside an agent's storage.
    public init(storeRoot: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.storeRoot = storeRoot.standardizedFileURL
        self.undoLog = UndoLog(directory: self.storeRoot.appendingPathComponent("Undo", isDirectory: true))
        self.now = now
    }

    // MARK: Execute

    public func execute(_ plan: Plan) throws -> UndoEntry {
        try execute(plan, batchID: nil)
    }

    /// Executes several plans as one undoable batch. Refuses up front if any plan is live or
    /// empty; stops at the first failure, leaving what ran so far undoable as a batch.
    public func execute(_ plans: [Plan]) throws -> [UndoEntry] {
        if let live = plans.first(where: { $0.liveCheck.isLive }) { throw ExecutorError.sessionIsLive(reasons: live.liveCheck.reasons) }
        guard !plans.isEmpty, !plans.contains(where: \.isEmpty) else { throw ExecutorError.nothingToDo }
        let batch = plans.count > 1 ? UUID() : nil
        return try plans.map { try execute($0, batchID: batch) }
    }

    private func execute(_ plan: Plan, batchID: UUID?) throws -> UndoEntry {
        guard !plan.liveCheck.isLive else { throw ExecutorError.sessionIsLive(reasons: plan.liveCheck.reasons) }
        guard !plan.isEmpty else { throw ExecutorError.nothingToDo }

        var entry = UndoEntry(
            id: UUID(),
            createdAt: now(),
            planID: plan.id,
            batchID: batchID,
            action: plan.action,
            agent: plan.agent,
            sessionID: plan.sessionID,
            destination: plan.destination,
            moved: [],
            indexRestores: [],
            compressed: [],
            undoneAt: nil,
            failure: nil
        )
        try undoLog.write(entry)
        if plan.action == .archive { return try compress(plan, entry: entry) }
        Log.executor.info("Executing plan \(plan.id, privacy: .public) for session \(plan.sessionID, privacy: .public): \(plan.moves.count) moves, \(plan.indexEdits.count) index edits")

        let present = plan.moves.filter { FileSystem.exists($0.source) }
        for (index, move) in present.enumerated() {
            do {
                let current = try relocate(move.source, to: plan.destination ?? .trash, entry: entry, ordinal: index)
                entry.moved.append(.init(original: move.source, current: current))
            } catch {
                entry.failure = error.localizedDescription
                try undoLog.write(entry)
                Log.executor.error("Move failed for \(move.source.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
                throw ExecutorError.moveFailed(move.source, reason: error.localizedDescription, movedSoFar: entry.moved.count, total: present.count)
            }
        }

        for edit in plan.indexEdits where FileSystem.exists(edit.file) {
            do {
                if let restore = try removeLines(edit, entry: entry) { entry.indexRestores.append(restore) }
            } catch {
                entry.failure = error.localizedDescription
                try undoLog.write(entry)
                throw ExecutorError.indexEditFailed(edit.file, reason: error.localizedDescription)
            }
        }

        try undoLog.write(entry)
        return entry
    }

    /// Archive: compress each planned file in place. Files that changed since planning are
    /// skipped (the agent may be writing), not treated as failures.
    private func compress(_ plan: Plan, entry original: UndoEntry) throws -> UndoEntry {
        var entry = original
        Log.executor.info("Archiving session \(plan.sessionID, privacy: .public): \(plan.compressions.count) files")
        let present = plan.compressions.filter { FileSystem.exists($0.file) }
        for item in present {
            do {
                switch try APFSCompression.compress(item.file, expected: item.modificationTime) {
                case .rewritten:
                    entry.compressed.append(.init(file: item.file, sizeBytes: item.sizeBytes))
                case .skipped(let reason):
                    Log.executor.info("Left \(item.file.path, privacy: .private) as is: \(reason, privacy: .public)")
                }
            } catch CompressionError.changedSincePlan(let url) {
                Log.executor.info("Left \(url.path, privacy: .private) as is: it changed since the plan")
            } catch {
                entry.failure = error.localizedDescription
                try undoLog.write(entry)
                Log.executor.error("Compression failed for \(item.file.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
                throw ExecutorError.compressionFailed(item.file, reason: error.localizedDescription, doneSoFar: entry.compressed.count, total: present.count)
            }
        }
        try undoLog.write(entry)
        return entry
    }

    private func relocate(_ source: URL, to destination: Destination, entry: UndoEntry, ordinal: Int) throws -> URL {
        switch destination {
        case .trash:
            var result: NSURL?
            try fileManager.trashItem(at: source, resultingItemURL: &result)
            guard let url = result as URL? else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "The Trash did not report where the item went."])
            }
            return url
        case .quarantine:
            let folder = quarantineDirectory.appendingPathComponent(entry.id.uuidString, isDirectory: true)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let target = folder.appendingPathComponent("\(ordinal)-\(source.lastPathComponent)")
            // moveItem renames within a volume, which keeps modification times intact.
            try fileManager.moveItem(at: source, to: target)
            return target
        }
    }

    /// Backs the index file up, drops the matching lines, and keeps mtime and permissions.
    private func removeLines(_ edit: IndexEdit, entry: UndoEntry) throws -> UndoEntry.IndexRestore? {
        let data = try Data(contentsOf: edit.file)
        var split = JSONLines.split(data)
        // Re-match instead of trusting plan-time line numbers: the agent may have appended since.
        let indices = JSONLines.indices(in: split.lines, where: edit.matchKey, equals: edit.matchValue)
        guard !indices.isEmpty else { return nil }

        let mtime = FileSystem.modificationTime(of: edit.file)
        let permissions = FileSystem.posixPermissions(of: edit.file)

        let backupDir = undoLog.backupDirectory(for: entry)
        try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backup = backupDir.appendingPathComponent(edit.file.lastPathComponent)
        try data.write(to: backup, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        if let mtime { try FileSystem.setModificationTime(mtime, of: backup) }

        let removed = indices.map { UndoEntry.RemovedLine(index: $0, bytes: split.lines[$0]) }
        for index in indices.reversed() { split.lines.remove(at: index) }
        try writePreservingMetadata(split.joined(), to: edit.file, modificationTime: mtime, permissions: permissions)

        return UndoEntry.IndexRestore(file: edit.file, backup: backup, removedLines: removed, modificationTime: mtime)
    }

    private func writePreservingMetadata(_ data: Data, to url: URL, modificationTime: FileTime?, permissions: Int?) throws {
        try data.write(to: url, options: [.atomic])
        if let permissions { try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
        if let modificationTime { try FileSystem.setModificationTime(modificationTime, of: url) }
    }

    // MARK: Undo

    public func undoLatest() throws -> UndoEntry {
        guard let entry = try undoLog.latestPending() else { throw ExecutorError.nothingToUndo }
        return try undo(entry)
    }

    /// Undoes the latest action; for a batch ("Archive all") every entry of it, newest first.
    public func undoLatestBatch() throws -> [UndoEntry] {
        let batch = try undoLog.latestPendingBatch()
        guard !batch.isEmpty else { throw ExecutorError.nothingToUndo }
        return try batch.map { try undo($0) }
    }

    public func undo(_ original: UndoEntry) throws -> UndoEntry {
        var entry = original
        guard !entry.isUndone else { throw ExecutorError.alreadyUndone }
        Log.executor.info("Undoing entry \(entry.id, privacy: .public)")

        // Put files back, last moved first, so parent folders exist before their children.
        var remaining = entry.moved
        for item in entry.moved.reversed() {
            do {
                try restore(item)
                remaining.removeAll { $0 == item }
            } catch {
                entry.moved = remaining
                try undoLog.write(entry)
                throw ExecutorError.restoreFailed(item.original, reason: error.localizedDescription)
            }
        }
        entry.moved = []

        // Decompress archived files. A file the agent rewrote or removed since is left as is.
        var stillCompressed = entry.compressed
        for item in entry.compressed {
            do {
                if FileSystem.exists(item.file) {
                    if case .skipped(let reason) = try APFSCompression.decompress(item.file) {
                        Log.executor.info("Left \(item.file.path, privacy: .private) as is: \(reason, privacy: .public)")
                    }
                }
                stillCompressed.removeAll { $0 == item }
            } catch {
                entry.compressed = stillCompressed
                try undoLog.write(entry)
                throw ExecutorError.restoreFailed(item.file, reason: error.localizedDescription)
            }
        }
        entry.compressed = []

        for restore in entry.indexRestores {
            do {
                try reinsert(restore)
            } catch {
                try undoLog.write(entry)
                throw ExecutorError.restoreFailed(restore.file, reason: error.localizedDescription)
            }
        }

        entry.undoneAt = now()
        try undoLog.write(entry)
        let folder = quarantineDirectory.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        if FileSystem.exists(folder), FileSystem.children(of: folder).isEmpty { try? fileManager.removeItem(at: folder) }
        return entry
    }

    private func restore(_ item: UndoEntry.MovedItem) throws {
        guard FileSystem.exists(item.current) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "it is no longer in \(item.current.deletingLastPathComponent().lastPathComponent) (was the Trash emptied?)"])
        }
        guard !FileSystem.exists(item.original) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "something else now exists at its original place"])
        }
        try fileManager.createDirectory(at: item.original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: item.current, to: item.original)
    }

    /// Puts removed lines back at their old positions. If the file vanished, the backup is restored whole.
    private func reinsert(_ restore: UndoEntry.IndexRestore) throws {
        guard FileSystem.exists(restore.file) else {
            try fileManager.copyItem(at: restore.backup, to: restore.file)
            if let mtime = restore.modificationTime { try FileSystem.setModificationTime(mtime, of: restore.file) }
            return
        }
        let permissions = FileSystem.posixPermissions(of: restore.file)
        var split = JSONLines.split(try Data(contentsOf: restore.file))
        for line in restore.removedLines.sorted(by: { $0.index < $1.index }) {
            split.lines.insert(line.bytes, at: min(line.index, split.lines.count))
        }
        if !split.lines.isEmpty { split.trailingNewline = true }
        try writePreservingMetadata(split.joined(), to: restore.file, modificationTime: restore.modificationTime, permissions: permissions)
    }
}
