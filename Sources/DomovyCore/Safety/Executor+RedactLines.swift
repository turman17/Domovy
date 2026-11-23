import Foundation

/// Line-level redaction for shared index files such as Claude Code's `history.jsonl`, which
/// every running session appends to. Only the planned lines are checked and rewritten, so
/// lines appended since the scan are kept, and undo puts back only those lines.
extension Executor {
    func redactLines(_ item: FileRedaction, ordinal: Int, matcher: SecretMatcher, entry: inout UndoEntry) throws {
        let file = item.file
        let mtime = FileSystem.modificationTime(of: file)
        let permissions = FileSystem.posixPermissions(of: file)
        let data = try Data(contentsOf: file)
        var bytes = [UInt8](data)
        var records: [UndoEntry.RedactedLine] = []
        // From the end, so the offsets of the lines still to do stay valid.
        for edit in item.lines.sorted(by: { $0.offset > $1.offset }) {
            let start = Int(edit.offset), end = start + edit.length
            guard start >= 0, end <= bytes.count,
                  start == 0 || bytes[start - 1] == UInt8(ascii: "\n"),
                  end == bytes.count || bytes[end] == UInt8(ascii: "\n") else {
                throw ExecutorError.changedSinceScan(file)
            }
            let redacted = try Self.redactedLine(Data(bytes[start..<end]), edit: edit, matcher: matcher)
            bytes.replaceSubrange(start..<end, with: redacted)
            records.append(.init(offset: edit.offset, length: edit.length, replacements: edit.replacements))
        }

        let folder = quarantineDirectory.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let kept = folder.appendingPathComponent("\(ordinal)-\(file.lastPathComponent)")
        // The backup: copyItem clones on APFS and keeps the modification time.
        try fileManager.copyItem(at: file, to: kept)
        var record = UndoEntry.RedactedItem(file: file, original: kept, modificationTime: mtime,
                                            replacements: item.replacementCount, sizeBytes: Int64(data.count))
        record.lines = records
        entry.redacted.append(record)
        try undoLog.write(entry)

        // Last look: a session that appended meanwhile wins and we back off.
        guard FileSystem.modificationTime(of: file) == mtime, FileSystem.size(of: file) == Int64(data.count) else {
            entry.redacted.removeLast()
            try? fileManager.removeItem(at: kept)
            throw ExecutorError.changedSinceScan(file)
        }
        try writePreservingMetadata(Data(bytes), to: file, modificationTime: mtime, permissions: permissions)
    }

    /// Finds each redacted line in the file as it is now and puts the original back. Lines
    /// added since stay; the file keeps its current modification time.
    func restoreLines(_ lines: [UndoEntry.RedactedLine], of item: UndoEntry.RedactedItem) throws {
        guard FileSystem.exists(item.file) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "the file is gone"])
        }
        let original = [UInt8](try Data(contentsOf: item.original))
        var split = JSONLines.split(try Data(contentsOf: item.file))
        for line in lines {
            let start = Int(line.offset), end = start + line.length
            guard start >= 0, end <= original.count else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "its original in Domovy's quarantine does not match the undo log"])
            }
            let before = Data(original[start..<end])
            var redacted = [UInt8](before)
            for replacement in line.replacements.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                redacted.replaceSubrange(replacement.range, with: Array(SecretRule.replacement(for: replacement.ruleID).utf8))
            }
            guard let index = split.lines.firstIndex(of: Data(redacted)) else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "a redacted line is no longer in it, so Domovy left it as it is"])
            }
            split.lines[index] = before
        }
        try writePreservingMetadata(split.joined(), to: item.file, modificationTime: FileSystem.modificationTime(of: item.file),
                                    permissions: FileSystem.posixPermissions(of: item.file))
        try fileManager.removeItem(at: item.original)
    }
}
