import Foundation

/// Why one file could not be rewritten. Never carries content.
enum RedactionError: Error, LocalizedError {
    case lineMoved(line: Int)
    case valueMoved(line: Int)
    case wouldBreakJSON(line: Int)

    var errorDescription: String? {
        switch self {
        case .lineMoved(let line): "line \(line) is not where the scan found it."
        case .valueMoved(let line): "a value on line \(line) no longer matches what the scan found."
        case .wouldBreakJSON(let line): "line \(line) would not be valid JSON afterwards."
        }
    }
}

extension Executor {
    /// Rewrites each file with its secrets replaced. Per file: write a redacted copy next to it,
    /// clone the original into the quarantine, record it in the undo log, then swap the copy
    /// in with one atomic rename. Modification time and permissions stay exactly as they were.
    func redact(_ plan: Plan, entry original: UndoEntry) throws -> UndoEntry {
        var entry = original
        let present = plan.redactions.filter { FileSystem.exists($0.file) }
        let matcher = SecretMatcher()
        for (index, item) in present.enumerated() {
            do {
                try redactFile(item, ordinal: index, matcher: matcher, entry: &entry)
            } catch {
                entry.failure = error.localizedDescription
                try undoLog.write(entry)
                if case ExecutorError.changedSinceScan = error { throw error }
                throw ExecutorError.redactionFailed(item.file, reason: error.localizedDescription, doneSoFar: entry.redacted.count, total: present.count)
            }
        }
        try undoLog.write(entry)
        SecretsLog.redacted(replacements: entry.redacted.reduce(0) { $0 + $1.replacements }, files: entry.redacted.count)
        return entry
    }

    private func redactFile(_ item: FileRedaction, ordinal: Int, matcher: SecretMatcher, entry: inout UndoEntry) throws {
        let file = item.file
        let mtime = FileSystem.modificationTime(of: file)
        let size = FileSystem.size(of: file)
        guard mtime == item.modificationTime, size == item.sizeBytes else { throw ExecutorError.changedSinceScan(file) }
        let permissions = FileSystem.posixPermissions(of: file)
        let parent = file.deletingLastPathComponent()
        let parentTime = FileSystem.modificationTime(of: parent)

        // Same folder, so the swap is one rename on one volume. No `.jsonl` in the name, so a
        // leftover never looks like a transcript to an agent.
        let staging = parent.appendingPathComponent(".domovy-redact-\(UUID().uuidString)")
        defer {
            if FileSystem.exists(staging) { try? fileManager.removeItem(at: staging) }
            if let parentTime { try? FileSystem.setModificationTime(parentTime, of: parent) }
        }
        try writeRedactedCopy(of: file, lines: item.lines, to: staging, matcher: matcher)
        if let permissions { try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: staging.path) }
        if let mtime { try FileSystem.setModificationTime(mtime, of: staging) }

        let folder = quarantineDirectory.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let kept = folder.appendingPathComponent("\(ordinal)-\(file.lastPathComponent)")
        // copyItem clones on APFS and keeps mtime, permissions and compression.
        try fileManager.copyItem(at: file, to: kept)
        entry.redacted.append(.init(file: file, original: kept, modificationTime: mtime, replacements: item.replacementCount, sizeBytes: size))
        try undoLog.write(entry)

        // Last look before the swap: an agent that wrote meanwhile wins and we back off.
        guard FileSystem.modificationTime(of: file) == mtime, FileSystem.size(of: file) == size else {
            entry.redacted.removeLast()
            try? fileManager.removeItem(at: kept)
            throw ExecutorError.changedSinceScan(file)
        }
        guard rename(staging.path, file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if item.wasCompressed { _ = try? APFSCompression.compress(file, expected: mtime) }
    }

    /// Streams `source` into `destination`, replacing the planned ranges. Each line is checked
    /// first: still at its offset, each value still matched by its rule, valid JSON afterwards.
    private func writeRedactedCopy(of source: URL, lines: [FileRedaction.LineEdit], to destination: URL, matcher: SecretMatcher) throws {
        guard fileManager.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Could not create a file next to it."])
        }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }
        var cursor: Int64 = 0
        func copy(upTo end: Int64) throws {
            while cursor < end {
                let count = Int(min(Int64(LineStream.chunkSize), end - cursor))
                guard let chunk = try input.read(upToCount: count), !chunk.isEmpty else { return }
                try output.write(contentsOf: chunk)
                cursor += Int64(chunk.count)
            }
        }

        for edit in lines.sorted(by: { $0.offset < $1.offset }) {
            try copy(upTo: edit.offset)
            guard cursor == edit.offset else { throw RedactionError.lineMoved(line: edit.line) }
            // The line plus the byte after it, which must end the line.
            let read = try input.read(upToCount: edit.length + 1) ?? Data()
            guard read.count >= edit.length, read.count == edit.length || read.last == UInt8(ascii: "\n") else {
                throw RedactionError.lineMoved(line: edit.line)
            }
            let line = read.prefix(edit.length)
            let found = Set(matcher.matches(in: Data(line)).map { "\($0.ruleID)@\($0.range)" })
            var bytes = [UInt8](line)
            for replacement in edit.replacements.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                guard found.contains("\(replacement.ruleID)@\(replacement.range)"),
                      JSONText.isInsideString(replacement.range, of: [UInt8](line)) else {
                    throw RedactionError.valueMoved(line: edit.line)
                }
                bytes.replaceSubrange(replacement.range, with: Array(SecretRule.replacement(for: replacement.ruleID).utf8))
            }
            guard JSONText.isValidJSON(Data(bytes)) else { throw RedactionError.wouldBreakJSON(line: edit.line) }
            try output.write(contentsOf: Data(bytes))
            if read.count > edit.length { try output.write(contentsOf: Data([UInt8(ascii: "\n")])) }
            cursor += Int64(read.count)
        }
        try copy(upTo: .max)
        try output.synchronize()
    }

    /// Puts each redacted file's original back, newest first. A file the agent wrote to since
    /// is left as it is and undo stops there.
    func restoreRedacted(_ entry: inout UndoEntry) throws {
        var remaining = entry.redacted
        for item in entry.redacted.reversed() {
            do {
                guard FileSystem.exists(item.original) else {
                    throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "its original is no longer in Domovy's quarantine"])
                }
                if FileSystem.exists(item.file), FileSystem.modificationTime(of: item.file) != item.modificationTime {
                    throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "it changed since it was redacted, so Domovy left it as it is"])
                }
                let parent = item.file.deletingLastPathComponent()
                let parentTime = FileSystem.modificationTime(of: parent)
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                guard rename(item.original.path, item.file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                if let parentTime { try? FileSystem.setModificationTime(parentTime, of: parent) }
                remaining.removeAll { $0 == item }
            } catch {
                entry.redacted = remaining
                try undoLog.write(entry)
                throw ExecutorError.restoreFailed(item.file, reason: error.localizedDescription)
            }
        }
        entry.redacted = []
    }
}

extension SecretRule {
    /// `[REDACTED:<rule>]`; ASCII without quotes or backslashes, so always safe in a JSON string.
    static func replacement(for ruleID: String) -> String {
        "[REDACTED:\(ruleID)]"
    }
}
