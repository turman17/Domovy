import Foundation

/// Copies kept before an agent's own command runs, and putting them back on undo. A command
/// that deletes for good (`ollama rm`, `hf cache rm`) never runs without them (safety rule 1).
extension Executor {
    /// What to keep for `command`: the files it declares, and for a permanent command also
    /// everything its checks expect to be gone. A folder covers whatever lies below it.
    static func filesToKeep(_ command: PlannedCommand) -> [URL] {
        let declared = command.copiesBeforeRun + (command.isPermanent ? command.verifications.flatMap(\.urls) : [])
        var result: [URL] = []
        for url in declared.map(\.standardizedFileURL) {
            guard !result.contains(where: { FileSystem.relativePath(of: url, under: $0) != nil }) else { continue }
            result.removeAll { FileSystem.relativePath(of: $0, under: url) != nil }
            result.append(url)
        }
        return result
    }

    /// Clones (or, failing that, copies) every file the command may remove into this entry's
    /// quarantine folder, with modes and modification times. Refuses the command when a copy
    /// cannot be made; copies made so far are dropped then.
    func keepCopies(for command: PlannedCommand, entry: inout UndoEntry) throws -> [UndoEntry.MovedItem] {
        let sources = Self.filesToKeep(command)
        if command.isPermanent, sources.isEmpty {
            entry.failure = "\(command.commandLine) did not run: nothing to keep a copy of"
            try undoLog.write(entry)
            throw ExecutorError.nothingToKeep(command: command.commandLine)
        }
        let folder = quarantineDirectory.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        var copies: [UndoEntry.MovedItem] = []
        for source in sources where FileSystem.itemExists(source) {
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let target = uniqueTarget(in: folder, name: "copy-\(source.lastPathComponent)")
                let metadata = KeptFileMetadata.record(source)
                let method = try copier.keep(source, at: target)
                copies.append(.init(original: source, current: target, kept: .init(method: method, metadata: metadata)))
            } catch {
                for copy in copies { try? fileManager.removeItem(at: copy.current) }
                entry.failure = "\(command.commandLine) did not run: no copy of \(source.lastPathComponent)"
                try undoLog.write(entry)
                Log.executor.error("Could not keep a copy of \(source.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
                throw ExecutorError.copyFailed(source, command: command.commandLine, reason: error.localizedDescription)
            }
        }
        return copies
    }

    /// The command removed something below a kept folder that it left in place.
    static func lostAnything(_ copy: UndoEntry.MovedItem) -> Bool {
        guard let kept = copy.kept else { return false }
        return kept.metadata.contains { !$0.path.isEmpty && !FileSystem.itemExists(copy.original.appendingPathComponent($0.path)) }
    }

    /// Puts a kept copy back: whole when the original is gone, otherwise only what is missing
    /// below the folder. Then restores modes and times, and checks everything is back.
    func restoreKept(_ item: UndoEntry.MovedItem) throws {
        guard let kept = item.kept else { return }
        guard FileSystem.itemExists(item.current) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "its copy is no longer in Domovy's quarantine"])
        }
        if !FileSystem.itemExists(item.original) {
            try fileManager.createDirectory(at: item.original.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: item.current, to: item.original)
        } else if Self.isSameBlob(item.original, item.current) {
            // Content-addressed and already back (pulled again since): the copy adds nothing.
            try? fileManager.removeItem(at: item.current)
            return
        } else {
            guard FileSystem.isDirectory(item.original), FileSystem.isDirectory(item.current) else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "something else now exists at its original place"])
            }
            var restored: [String] = []
            for entry in kept.metadata.sorted(by: { $0.path < $1.path }) where !entry.path.isEmpty {
                guard !restored.contains(where: { entry.path.hasPrefix($0 + "/") }) else { continue }
                let target = item.original.appendingPathComponent(entry.path)
                guard !FileSystem.itemExists(target) else { continue }
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: item.current.appendingPathComponent(entry.path), to: target)
                restored.append(entry.path)
            }
            try? fileManager.removeItem(at: item.current)
        }
        KeptFileMetadata.apply(kept.metadata, to: item.original)
        let missing = kept.metadata.filter { !FileSystem.itemExists($0.path.isEmpty ? item.original : item.original.appendingPathComponent($0.path)) }
        guard missing.isEmpty else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "\(missing.count) of its files did not come back"])
        }
    }

    /// Two regular files of a content-addressed store (Ollama's `sha256-<hex>` blobs, Hugging
    /// Face's `blobs/<hex>`) with the same name and size: the name is the digest of the content,
    /// so they are the same file.
    static func isSameBlob(_ original: URL, _ copy: URL) -> Bool {
        guard isContentAddressed(original),
              let a = try? original.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              let b = try? copy.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              a.isRegularFile == true, b.isRegularFile == true else { return false }
        return a.fileSize == b.fileSize
    }

    static func isContentAddressed(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let hex = name.hasPrefix("sha256-") ? String(name.dropFirst(7)) : name
        let inBlobs = url.deletingLastPathComponent().lastPathComponent == "blobs"
        return inBlobs && (hex.count == 64 || hex.count == 40) && hex.allSatisfy(\.isHexDigit)
    }

    private func uniqueTarget(in folder: URL, name: String) -> URL {
        var target = folder.appendingPathComponent(name)
        var n = 1
        while FileSystem.itemExists(target) {
            target = folder.appendingPathComponent("\(n)-\(name)")
            n += 1
        }
        return target
    }
}
