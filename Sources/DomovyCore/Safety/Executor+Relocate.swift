import Darwin
import Foundation

/// Moving an item out of an agent's storage: to the Trash, or into this entry's quarantine
/// folder. A move to another volume is a full copy that is checked before the source goes.
extension Executor {
    func relocate(_ source: URL, to destination: Destination, entry: UndoEntry, ordinal: Int) throws -> URL {
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
            if Self.isSameVolume(source, folder) {
                // A rename within a volume, which keeps modification times intact.
                try fileManager.moveItem(at: source, to: target)
            } else {
                try moveAcrossVolumes(source, to: target)
            }
            return target
        }
    }

    /// Copies everything, checks the copy has every item with its size, and only then removes
    /// the source. Any failure before that removes the partial copy and leaves the source as it
    /// was. If the source cannot be removed in full, the complete copy still counts as moved.
    func moveAcrossVolumes(_ source: URL, to target: URL) throws {
        let expected = KeptFileMetadata.record(source)
        do {
            try QuarantineCopier.copyItem(source, target)
            KeptFileMetadata.apply(expected, to: target)
            guard Self.sameItems(source, target) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "the copy on the other volume is not complete"])
            }
        } catch {
            try? fileManager.removeItem(at: target)
            throw error
        }
        do {
            try fileManager.removeItem(at: source)
        } catch {
            // The full copy is recorded and kept; what is left of the source stays where it was.
            Log.executor.error("Copied \(source.path, privacy: .private) to the quarantine but could not remove all of it: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func isSameVolume(_ a: URL, _ b: URL) -> Bool {
        var first = stat(), second = stat()
        guard lstat(a.path, &first) == 0, lstat(b.path, &second) == 0 else { return false }
        return first.st_dev == second.st_dev
    }

    /// Every item below `source` is at the same place below `copy`, regular files with the same size.
    static func sameItems(_ source: URL, _ copy: URL) -> Bool {
        let items = KeptFileMetadata.record(source).map(\.path)
        return items.allSatisfy { path in
            let a = path.isEmpty ? source : source.appendingPathComponent(path)
            let b = path.isEmpty ? copy : copy.appendingPathComponent(path)
            var left = stat(), right = stat()
            guard lstat(a.path, &left) == 0, lstat(b.path, &right) == 0, left.st_mode & S_IFMT == right.st_mode & S_IFMT else { return false }
            return left.st_mode & S_IFMT != S_IFREG || left.st_size == right.st_size
        }
    }
}

/// Moves within the agent's own folder (an archive the agent understands, such as Qwen Code's
/// `chats/archive/`). Each is a rename on one volume, which keeps modification times; one that
/// would cross volumes or land on an existing item is refused before anything moves.
extension Executor {
    func relocate(_ relocations: [FileRelocation], entry: inout UndoEntry) throws {
        let present = relocations.filter { FileSystem.exists($0.source) }
        for item in present {
            if FileSystem.exists(item.target) {
                throw ExecutorError.moveFailed(item.source, reason: "\(item.target.lastPathComponent) already exists in \(item.target.deletingLastPathComponent().lastPathComponent)/", movedSoFar: 0, total: present.count)
            }
        }
        for item in present {
            do {
                let folder = item.target.deletingLastPathComponent()
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                guard Self.isSameVolume(item.source, folder) else {
                    throw CocoaError(.fileWriteVolumeReadOnly, userInfo: [NSLocalizedDescriptionKey: "the target folder is on another volume"])
                }
                try fileManager.moveItem(at: item.source, to: item.target)
                entry.relocated.append(.init(original: item.source, current: item.target))
                try undoLog.write(entry)
            } catch {
                entry.failure = error.localizedDescription
                try undoLog.write(entry)
                throw ExecutorError.moveFailed(item.source, reason: error.localizedDescription, movedSoFar: entry.relocated.count, total: present.count)
            }
        }
    }

    /// Moves relocated items back, last first. One the agent moved back or removed itself is
    /// left as it is; one whose original place is taken again stops the undo.
    func restoreRelocated(_ entry: inout UndoEntry) throws {
        var remaining = entry.relocated
        for item in entry.relocated.reversed() {
            if FileSystem.exists(item.current) {
                guard !FileSystem.exists(item.original) else {
                    entry.relocated = remaining
                    try undoLog.write(entry)
                    throw ExecutorError.restoreFailed(item.original, reason: "something else now exists at its original place")
                }
                do {
                    try fileManager.moveItem(at: item.current, to: item.original)
                } catch {
                    entry.relocated = remaining
                    try undoLog.write(entry)
                    throw ExecutorError.restoreFailed(item.original, reason: error.localizedDescription)
                }
            } else {
                Log.executor.info("Left \(item.original.path, privacy: .private) as is: it is no longer where the archive put it")
            }
            remaining.removeAll { $0 == item }
        }
        entry.relocated = []
    }
}
