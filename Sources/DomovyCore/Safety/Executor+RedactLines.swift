import Foundation

/// Line-level redaction for shared index files such as Claude Code's `history.jsonl`, which
/// every running session appends to. Only the planned lines are checked and rewritten, so
/// lines appended since the scan are kept, and undo puts back only those lines. Both go
/// through `IndexFileRewrite`, so lines appended while Domovy works are kept too.
extension Executor {
    func redactLines(_ item: FileRedaction, ordinal: Int, matcher: SecretMatcher, entry: inout UndoEntry) throws {
        let file = item.file
        let folder = quarantineDirectory.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        let kept = folder.appendingPathComponent("\(ordinal)-\(file.lastPathComponent)")
        let recorded = entry.redacted.count
        do {
            try IndexFileRewrite.rewrite(file, hook: indexRewriteHook) { data, mtime in
                // An earlier attempt read bytes that changed since.
                entry.redacted.removeSubrange(recorded...)
                if FileSystem.itemExists(kept) { try fileManager.removeItem(at: kept) }

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

                // The backup is exactly the bytes being replaced, recorded before the swap.
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                guard fileManager.createFile(atPath: kept.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Could not keep the original in Domovy's quarantine."])
                }
                try FileSystem.setModificationTime(mtime, of: kept)
                var record = UndoEntry.RedactedItem(file: file, original: kept, modificationTime: mtime,
                                                    replacements: item.replacementCount, sizeBytes: Int64(data.count))
                record.lines = records
                entry.redacted.append(record)
                try undoLog.write(entry)
                return Data(bytes)
            }
        } catch {
            entry.redacted.removeSubrange(recorded...)
            if FileSystem.itemExists(kept) { try? fileManager.removeItem(at: kept) }
            throw error
        }
    }

    /// Finds each redacted line in the file as it is now and puts the original back. Lines
    /// added since stay; the file keeps its current modification time.
    func restoreLines(_ lines: [UndoEntry.RedactedLine], of item: UndoEntry.RedactedItem) throws {
        guard FileSystem.exists(item.file) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "the file is gone"])
        }
        let original = [UInt8](try Data(contentsOf: item.original))
        try IndexFileRewrite.rewrite(item.file, hook: indexRewriteHook) { data, _ in
            var split = JSONLines.split(data)
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
            return split.joined()
        }
        try fileManager.removeItem(at: item.original)
    }
}
