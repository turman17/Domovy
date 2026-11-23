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
    case appRunning(reasons: [String])
    case commandFailed(String, status: Int32, message: String)
    case changedSinceScan(URL)
    case redactionFailed(URL, reason: String, doneSoFar: Int, total: Int)
    case originalsPurged
    case notInQuarantine(URL)
    case copyFailed(URL, command: String, reason: String)
    case nothingToKeep(command: String)
    case needsAcknowledgement(String)
    case changedSinceCommand(URL, agent: String)
    case snapshotFailed(URL, reason: String)
    case filesOpen(reasons: [String])
    case databaseEditFailed(URL, reason: String)
    case integrityCheckFailed(URL, problems: [String], restored: Bool)
    case outsideScope(URL)
    case commandFailedPartly(String, status: Int32, message: String)
    case indexKeptChanging(URL)

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
        case .appRunning(let reasons):
            "Nothing was changed. " + reasons.joined(separator: " ")
        case .commandFailed(let line, let status, let message):
            "`\(line)` failed (exit status \(status))\(message.isEmpty ? "." : ": \(message)") Its files were left as they were."
        case .changedSinceScan(let url):
            "\(url.lastPathComponent) changed since the scan, so Domovy left it as it is. Scan again, then redact."
        case .redactionFailed(let url, let reason, let done, let total):
            "Could not redact \(url.lastPathComponent): \(reason) \(done) of \(total) files were redacted; run undo to put the originals back."
        case .originalsPurged:
            "This cannot be undone: its originals were permanently deleted with Purge originals."
        case .notInQuarantine(let url):
            "Refusing to delete \(url.lastPathComponent): it is not inside Domovy's quarantine folder."
        case .copyFailed(let url, let command, let reason):
            "Domovy could not keep a copy of \(url.lastPathComponent) (\(reason)), so it did not run `\(command)`. Nothing was deleted."
        case .nothingToKeep(let command):
            "Domovy does not know which files `\(command)` deletes, so it cannot keep a copy and did not run it."
        case .needsAcknowledgement(let text):
            "Nothing was changed: this needs your explicit OK first. \(text)"
        case .changedSinceCommand(let url, let agent):
            "\(agent) changed \(url.lastPathComponent) after the delete, so putting the old copy back would lose those changes. This delete can no longer be undone; Domovy's copy stays in its quarantine until you purge it."
        case .snapshotFailed(let url, let reason):
            "Domovy could not keep a copy of \(url.lastPathComponent) (\(reason)), so it changed nothing."
        case .filesOpen(let reasons):
            "Nothing was changed. " + reasons.joined(separator: " ")
        case .databaseEditFailed(let url, let reason):
            "Could not edit \(url.lastPathComponent): \(reason). Nothing in it was changed."
        case .integrityCheckFailed(let url, let problems, let restored):
            restored
                ? "\(url.lastPathComponent) failed SQLite's integrity check after the edit (\(problems.first ?? "no answer")), so Domovy put its copy of the database back. Nothing was changed."
                : "\(url.lastPathComponent) failed SQLite's integrity check after the edit (\(problems.first ?? "no answer")), and Domovy could not put its copy back. The copy is in Domovy's quarantine; quit the app and use Undo, or replace the file with it."
        case .outsideScope(let url):
            "Refusing to change \(url.lastPathComponent): it is outside the folders this action may change, so Domovy changed nothing."
        case .commandFailedPartly(let line, let status, let message):
            "`\(line)` failed (exit status \(status))\(message.isEmpty ? "." : ": \(message)") It had already changed some files; Domovy kept copies, so undo puts them back."
        case .indexKeptChanging(let url):
            "\(url.lastPathComponent) kept changing while Domovy edited it (an agent is writing to it), so Domovy left it as it is. Try again in a moment."
        }
    }
}

/// Executes a `Plan` reversibly and undoes it later. Files go to the Trash or to a
/// quarantine folder under `storeRoot`; every run writes an undo entry first thing.
public struct Executor: Sendable {
    public let storeRoot: URL
    public let undoLog: UndoLog
    let runner: any CommandRunner
    let processes: any RunningProcessLister
    let copier: QuarantineCopier
    let integrity: any DatabaseIntegrityChecker
    let now: @Sendable () -> Date
    /// Called between reading a shared index file and swapping in its new version; tests
    /// append a line here, the way a running agent would.
    var indexRewriteHook: IndexFileRewrite.Hook?
    var fileManager: FileManager { .default }

    public var quarantineDirectory: URL { storeRoot.appendingPathComponent("Quarantine", isDirectory: true) }

    /// - Parameter storeRoot: Domovy's own folder (app: `~/Library/Application Support/Domovy`;
    ///   tests: a temp dir). Never a folder inside an agent's storage.
    ///   - runner: runs agent commands such as `codex delete`; tests point plans at a stub executable.
    ///   - processes: checks right before execution that apps a plan must not run alongside are quit.
    ///   - copier: keeps copies of what a tool command deletes; tests make it fail on purpose.
    ///   - integrity: checks a database after Domovy edited it; tests make it fail on purpose.
    public init(
        storeRoot: URL,
        runner: any CommandRunner = ProcessCommandRunner(),
        processes: any RunningProcessLister = LibprocProcessLister(),
        copier: QuarantineCopier = .system,
        integrity: any DatabaseIntegrityChecker = SQLiteIntegrityChecker(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.storeRoot = storeRoot.standardizedFileURL
        self.undoLog = UndoLog(directory: self.storeRoot.appendingPathComponent("Undo", isDirectory: true))
        self.runner = runner
        self.processes = processes
        self.copier = copier
        self.integrity = integrity
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
        if plan.needsAcknowledgement, let text = plan.acknowledgement { throw ExecutorError.needsAcknowledgement(text) }
        try requireInScope(plan)
        // Checked again here: the app may have started while the user read the plan.
        let blocking = processes.blockingReasons(plan.mustNotBeRunning)
        guard blocking.isEmpty else { throw ExecutorError.appRunning(reasons: blocking) }
        // An agent may have opened the session since the plan. Files rewritten in place are
        // checked again one by one, right before each swap.
        try requireNotOpen(plan.moves.map(\.source) + plan.registryRemovals.map(\.file))

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
            undoCommands: [],
            mustNotBeRunning: plan.mustNotBeRunning,
            leftovers: [],
            undoneAt: nil,
            failure: nil,
            secretFindingCount: plan.secretFindingCount
        )
        entry.scope = plan.scope
        try undoLog.write(entry)
        for command in plan.commands {
            try run(command, entry: &entry)
        }
        for edit in plan.databaseEdits where !edit.isEmpty {
            try editDatabase(edit, entry: &entry)
        }
        if plan.action == .archive { return try compress(plan, entry: entry) }
        if plan.action == .redact { return try redact(plan, entry: entry) }
        Log.executor.info("Executing plan \(plan.id, privacy: .public) for session \(plan.sessionID, privacy: .public): \(plan.moves.count) moves, \(plan.indexEdits.count) index edits, \(plan.registryRemovals.count) registry entries")

        let present = plan.moves.filter { FileSystem.exists($0.source) }
        for (index, move) in present.enumerated() {
            do {
                let current = try relocate(move.source, to: plan.destination ?? .trash, entry: entry, ordinal: index)
                entry.moved.append(.init(original: move.source, current: current))
                // Written after every step, so a crash or a full disk never hides a moved file from undo.
                try undoLog.write(entry)
            } catch {
                entry.failure = error.localizedDescription
                try undoLog.write(entry)
                Log.executor.error("Move failed for \(move.source.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
                throw ExecutorError.moveFailed(move.source, reason: error.localizedDescription, movedSoFar: entry.moved.count, total: present.count)
            }
        }

        for edit in plan.indexEdits where FileSystem.exists(edit.file) {
            do {
                if let restore = try removeLines(edit, entry: entry) {
                    entry.indexRestores.append(restore)
                    try undoLog.write(entry)
                }
            } catch {
                entry.failure = error.localizedDescription
                try undoLog.write(entry)
                throw ExecutorError.indexEditFailed(edit.file, reason: error.localizedDescription)
            }
        }

        for (index, removal) in plan.registryRemovals.enumerated() where FileSystem.exists(removal.file) {
            do {
                if let restore = try removeRegistryFile(removal, destination: plan.destination ?? .trash, entry: entry, ordinal: present.count + index) {
                    entry.registryRestores.append(restore)
                    try undoLog.write(entry)
                }
            } catch {
                entry.failure = error.localizedDescription
                try undoLog.write(entry)
                throw ExecutorError.indexEditFailed(removal.file, reason: error.localizedDescription)
            }
        }

        // A permanent tool command with nothing kept or moved leaves nothing to put back.
        if plan.commands.contains(where: \.isPermanent), entry.moved.isEmpty, entry.indexRestores.isEmpty,
           entry.undoCommands.isEmpty, entry.registryRestores.isEmpty {
            entry.irreversible = true
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
                let outcome = try APFSCompression.compress(item.file, expected: item.modificationTime) {
                    try requireNotOpen([item.file])
                }
                switch outcome {
                case .rewritten:
                    entry.compressed.append(.init(file: item.file, sizeBytes: item.sizeBytes))
                    try undoLog.write(entry)
                case .skipped(let reason):
                    Log.executor.info("Left \(item.file.path, privacy: .private) as is: \(reason, privacy: .public)")
                }
            } catch CompressionError.changedSincePlan(let url) {
                Log.executor.info("Left \(url.path, privacy: .private) as is: it changed since the plan")
            } catch let error as ExecutorError {
                entry.failure = error.localizedDescription
                try undoLog.write(entry)
                throw error
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

    /// Runs one agent command: keeps copies of what it will remove, runs it, then checks what
    /// it left behind. Whatever the command removed or rewrote, even when it failed or timed out
    /// half way, stays recorded so undo can put it back.
    private func run(_ command: PlannedCommand, entry: inout UndoEntry) throws {
        let sessionID = entry.sessionID
        Log.executor.info("Running \(command.executable.lastPathComponent, privacy: .public) \(command.arguments.first ?? "", privacy: .public) for session \(sessionID, privacy: .public)")
        try takeSnapshots(for: command, entry: &entry)
        let copies: [UndoEntry.MovedItem]
        do {
            copies = try keepCopies(for: command, entry: &entry)
        } catch {
            settleSnapshots(&entry)
            try? undoLog.write(entry)
            throw error
        }
        var captured: [UndoEntry.IndexRestore] = []
        do {
            for edit in command.indexLinesBeforeRun where FileSystem.exists(edit.file) {
                if let restore = try snapshotLines(edit, entry: entry) { captured.append(restore) }
            }
        } catch {
            // The command does not run: nothing it would remove may stay behind unrecorded.
            for copy in copies { try? fileManager.removeItem(at: copy.current) }
            for restore in captured { try? fileManager.removeItem(at: restore.backup) }
            settleSnapshots(&entry)
            entry.failure = "\(command.commandLine) did not run: \(error.localizedDescription)"
            try? undoLog.write(entry)
            throw error
        }

        let result: CommandResult
        do {
            result = try runner.run(command)
        } catch {
            result = CommandResult(status: -1, errorOutput: error.localizedDescription)
        }
        // Whatever the command changed in place, even when it failed, undo can put back.
        settleSnapshots(&entry)
        let kept = keepWhatWasRemoved(copies, lines: captured, entry: &entry)
        guard result.status == 0 else {
            entry.failure = "\(command.commandLine) exited with status \(result.status)"
            try undoLog.write(entry)
            Log.executor.error("\(command.commandLine, privacy: .public) failed with \(result.status, privacy: .public): \(result.errorOutput, privacy: .private)")
            if kept || !entry.snapshots.isEmpty {
                throw ExecutorError.commandFailedPartly(command.commandLine, status: result.status, message: result.errorOutput)
            }
            throw ExecutorError.commandFailed(command.commandLine, status: result.status, message: result.errorOutput)
        }

        entry.undoCommands.append(contentsOf: command.undo)
        let leftovers = command.verifications.compactMap { $0.leftover() }
        entry.leftovers.append(contentsOf: leftovers)
        if !leftovers.isEmpty {
            Log.executor.info("\(command.commandLine, privacy: .public) left \(leftovers.count, privacy: .public) things behind")
        }
        try undoLog.write(entry)
    }

    /// Records the copies of what the command really removed, even in part, and the index lines
    /// it removed; drops the rest. True when anything was recorded.
    private func keepWhatWasRemoved(_ copies: [UndoEntry.MovedItem], lines captured: [UndoEntry.IndexRestore], entry: inout UndoEntry) -> Bool {
        var kept = false
        for copy in copies {
            if FileSystem.itemExists(copy.original), !Self.lostAnything(copy) {
                try? fileManager.removeItem(at: copy.current)
            } else {
                entry.moved.append(copy)
                kept = true
                if copy.kept?.method == .copy {
                    entry.notes.append("APFS could not clone \(copy.original.lastPathComponent), so Domovy kept a full copy (\(CleanupPlan.bytes(DiskUsage.measure(copy.current).allocated))) in its quarantine.")
                }
            }
        }
        for restore in captured {
            let data = (try? Data(contentsOf: restore.file)) ?? Data()
            let remaining = restore.removedLines.filter { line in JSONLines.split(data).lines.contains(line.bytes) }
            if remaining.count < restore.removedLines.count {
                entry.indexRestores.append(restore)
                kept = true
            } else {
                try? fileManager.removeItem(at: restore.backup)
            }
        }
        return kept
    }

    /// Records the lines an agent command is about to remove, with a byte-exact backup.
    private func snapshotLines(_ edit: IndexEdit, entry: UndoEntry) throws -> UndoEntry.IndexRestore? {
        let data = try Data(contentsOf: edit.file)
        let split = JSONLines.split(data)
        let indices = JSONLines.indices(in: split.lines, where: edit.matchKey, equals: edit.matchValue)
        guard !indices.isEmpty else { return nil }
        let mtime = FileSystem.modificationTime(of: edit.file)
        let backup = try writeBackup(data, of: edit.file, entry: entry, modificationTime: mtime)
        let removed = indices.map { UndoEntry.RemovedLine(index: $0, bytes: split.lines[$0]) }
        return UndoEntry.IndexRestore(file: edit.file, backup: backup, removedLines: removed, modificationTime: mtime)
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

    /// Undoes `original` as it is on disk now: another window or `domo` may have undone or
    /// purged it since this copy was read. One undo at a time, across processes.
    public func undo(_ original: UndoEntry) throws -> UndoEntry {
        try undoLog.withLock {
            guard let current = try undoLog.entry(id: original.id) else { throw ExecutorError.nothingToUndo }
            return try undoNow(current)
        }
    }

    private func undoNow(_ found: UndoEntry) throws -> UndoEntry {
        var entry = found
        guard !entry.isUndone else { throw ExecutorError.alreadyUndone }
        guard entry.originalsPurgedAt == nil else { throw ExecutorError.originalsPurged }
        try requireInScope(entry)
        Log.executor.info("Undoing entry \(entry.id, privacy: .public)")
        let blocking = processes.blockingReasons(entry.mustNotBeRunning)
        guard blocking.isEmpty else { throw ExecutorError.appRunning(reasons: blocking) }

        // Reverse agent commands first (e.g. `codex unarchive`), newest first.
        var pendingCommands = entry.undoCommands
        for command in entry.undoCommands.reversed() {
            let result = (try? runner.run(command)) ?? CommandResult(status: -1, errorOutput: "")
            guard result.status == 0 else {
                entry.undoCommands = pendingCommands
                try undoLog.write(entry)
                throw ExecutorError.commandFailed(command.commandLine, status: result.status, message: result.errorOutput)
            }
            pendingCommands.removeLast()
        }
        entry.undoCommands = []

        // Databases a command rewrote in place, only if nothing wrote to them since and nothing
        // holds them open now.
        try requireNotOpen(entry.snapshots.map(\.original))
        do {
            try restoreSnapshots(&entry)
        } catch let error as ExecutorError {
            if case .changedSinceCommand = error {
                entry.irreversible = true
                entry.notes.append(error.localizedDescription)
            }
            try undoLog.write(entry)
            throw error
        }

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
                    if case .skipped(let reason) = try APFSCompression.decompress(item.file, beforeSwap: { try requireNotOpen([item.file]) }) {
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

        try restoreRedacted(&entry)
        try restoreRegistryFiles(&entry)

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
        if item.kept != nil { return try restoreKept(item) }
        guard FileSystem.exists(item.current) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "it is no longer in \(item.current.deletingLastPathComponent().lastPathComponent) (was the Trash emptied?)"])
        }
        guard !FileSystem.exists(item.original) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "something else now exists at its original place"])
        }
        try fileManager.createDirectory(at: item.original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: item.current, to: item.original)
    }
}
