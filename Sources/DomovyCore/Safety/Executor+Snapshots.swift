import Darwin
import Foundation

/// Size, modification time and file number of a file: enough to tell whether anything wrote to
/// it, without reading a database that may be gigabytes large.
public struct FileFingerprint: Codable, Sendable, Hashable {
    public let size: Int64
    public let modificationTime: FileTime
    public let inode: UInt64

    /// `nil` when nothing is there.
    init?(of url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        size = Int64(info.st_size)
        modificationTime = FileTime(seconds: Int64(info.st_mtimespec.tv_sec), nanoseconds: Int64(info.st_mtimespec.tv_nsec))
        inode = UInt64(info.st_ino)
    }
}

/// Clones of files an agent command rewrites in place (OpenCode's `opencode.db`), and putting
/// them back on undo. A database the agent wrote to since is never replaced: that would lose
/// whatever it wrote (safety rule 1 both ways).
extension Executor {
    /// Clones each planned file that exists, before the command runs. Files already cloned by an
    /// earlier command of the same plan are not cloned again. Refuses the command when a clone
    /// cannot be made.
    func takeSnapshots(for command: PlannedCommand, entry: inout UndoEntry) throws {
        try takeSnapshots(of: command.snapshotsBeforeRun, entry: &entry,
                          failure: "\(command.commandLine) did not run") { source, reason in
            ExecutorError.copyFailed(source, command: command.commandLine, reason: reason)
        }
    }

    /// Clones `files` before something rewrites them in place (a command, or Domovy's own
    /// database edit). `refusal` builds the error thrown when a clone cannot be made.
    func takeSnapshots(of files: [URL], entry: inout UndoEntry, failure: String,
                       refusal: (URL, String) -> ExecutorError) throws {
        let taken = Set(entry.snapshots.map(\.original))
        let folder = quarantineDirectory.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        for source in files.map(\.standardizedFileURL) where !taken.contains(source) {
            let compared = !source.lastPathComponent.hasSuffix("-shm")
            guard FileSystem.itemExists(source) else {
                entry.snapshots.append(.init(original: source, copy: nil, metadata: [], before: nil, after: nil, isCompared: compared))
                continue
            }
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let target = folder.appendingPathComponent("snapshot-\(entry.snapshots.count)-\(source.lastPathComponent)")
                let metadata = KeptFileMetadata.record(source)
                let before = FileFingerprint(of: source)
                _ = try copier.keep(source, at: target)
                entry.snapshots.append(.init(original: source, copy: target, metadata: metadata, before: before, after: nil, isCompared: compared))
            } catch {
                for item in entry.snapshots { if let copy = item.copy { try? fileManager.removeItem(at: copy) } }
                entry.snapshots = []
                entry.failure = "\(failure): no copy of \(source.lastPathComponent)"
                try undoLog.write(entry)
                Log.executor.error("Could not keep a copy of \(source.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
                throw refusal(source, error.localizedDescription)
            }
        }
    }

    /// Records how the files look after a command. When nothing changed at all, the clones are
    /// dropped: there is nothing to put back.
    func settleSnapshots(_ entry: inout UndoEntry) {
        for index in entry.snapshots.indices {
            entry.snapshots[index].after = FileFingerprint(of: entry.snapshots[index].original)
        }
        let unchanged = entry.snapshots.allSatisfy { !$0.isCompared || $0.before == $0.after }
        guard unchanged else { return }
        for item in entry.snapshots { if let copy = item.copy { try? fileManager.removeItem(at: copy) } }
        entry.snapshots = []
    }

    /// Puts the clones back, all or nothing, after checking that no compared file changed since
    /// the command. The agent's app must be quit (checked by the caller).
    func restoreSnapshots(_ entry: inout UndoEntry) throws {
        guard !entry.snapshots.isEmpty else { return }
        let agent = entry.agent.displayName
        for item in entry.snapshots where item.isCompared && FileFingerprint(of: item.original) != item.after {
            throw ExecutorError.changedSinceCommand(item.original, agent: agent)
        }
        for item in entry.snapshots {
            if let copy = item.copy, !FileSystem.itemExists(copy) {
                throw ExecutorError.restoreFailed(item.original, reason: "its copy is no longer in Domovy's quarantine")
            }
        }
        // The current files step aside first, so a failure half way can put them back.
        let folder = quarantineDirectory.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        var aside: [(original: URL, moved: URL)] = []
        var restored: [URL] = []
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (index, item) in entry.snapshots.enumerated() where FileSystem.itemExists(item.original) {
                let target = folder.appendingPathComponent("replaced-\(index)-\(item.original.lastPathComponent)")
                try fileManager.moveItem(at: item.original, to: target)
                aside.append((item.original, target))
            }
            for item in entry.snapshots {
                guard let copy = item.copy else { continue }
                try fileManager.moveItem(at: copy, to: item.original)
                restored.append(item.original)
                KeptFileMetadata.apply(item.metadata, to: item.original)
            }
        } catch {
            for (original, copy) in zip(restored, entry.snapshots.compactMap(\.copy)) { try? fileManager.moveItem(at: original, to: copy) }
            for (original, moved) in aside { try? fileManager.moveItem(at: moved, to: original) }
            Log.executor.error("Could not put back the copy of \(agent, privacy: .public)'s database: \(error.localizedDescription, privacy: .public)")
            throw ExecutorError.restoreFailed(entry.snapshots[0].original, reason: error.localizedDescription)
        }
        // What the delete left is not needed once the old files are back.
        for (_, moved) in aside { try? fileManager.removeItem(at: moved) }
        entry.snapshots = []
    }
}
