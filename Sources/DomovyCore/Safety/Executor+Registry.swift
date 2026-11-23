import Foundation

extension Executor {
    /// Removes one registry file: checks it still names the planned session, keeps a byte-exact
    /// backup with its modification time, then moves it like any other file. A file that now
    /// names another session is left alone.
    func removeRegistryFile(_ removal: RegistryRemoval, destination: Destination, entry: UndoEntry, ordinal: Int) throws -> UndoEntry.RegistryRestore? {
        let data = try Data(contentsOf: removal.file)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object[removal.matchKey] as? String)?.lowercased() == removal.matchValue.lowercased() else {
            Log.executor.info("Left \(removal.file.path, privacy: .private) as is: it no longer names the planned session")
            return nil
        }
        let mtime = FileSystem.modificationTime(of: removal.file)
        let backup = try writeBackup(data, of: removal.file, entry: entry, modificationTime: mtime)
        let current = try relocate(removal.file, to: destination, entry: entry, ordinal: ordinal)
        return UndoEntry.RegistryRestore(file: removal.file, backup: backup, current: current, modificationTime: mtime)
    }

    /// Puts removed registry files back, newest first, with their modification times.
    func restoreRegistryFiles(_ entry: inout UndoEntry) throws {
        var remaining = entry.registryRestores
        for item in entry.registryRestores.reversed() {
            do {
                guard !FileSystem.exists(item.file) else {
                    throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "something else now exists at its original place"])
                }
                try fileManager.createDirectory(at: item.file.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileSystem.exists(item.current) {
                    try fileManager.moveItem(at: item.current, to: item.file)
                } else {
                    try fileManager.copyItem(at: item.backup, to: item.file)
                }
                if let mtime = item.modificationTime { try FileSystem.setModificationTime(mtime, of: item.file) }
                remaining.removeAll { $0 == item }
            } catch {
                entry.registryRestores = remaining
                try undoLog.write(entry)
                throw ExecutorError.restoreFailed(item.file, reason: error.localizedDescription)
            }
        }
        entry.registryRestores = []
    }
}
