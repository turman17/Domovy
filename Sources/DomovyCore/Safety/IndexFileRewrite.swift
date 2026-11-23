import Darwin
import Foundation

/// Rewrites a shared index file that agents keep appending to (`history.jsonl`,
/// `session_index.jsonl`) without losing what they append meanwhile: read, build the new
/// bytes, stage them next to the file, and swap them in only if size, modification time and
/// file number are still what was read. Otherwise start over from the new contents, a few
/// times, then give up and leave the file as it is.
///
/// A symlinked index stays a symlink: the file it points to is rewritten. The staged copy gets
/// the file's mode, extended attributes and the modification time of what was read, so a
/// rewrite never moves the time back over a newer append (safety rule 5).
enum IndexFileRewrite {
    static let attempts = 5

    /// Called between building the new bytes and the swap. Tests append a line here, the way a
    /// running agent would.
    typealias Hook = @Sendable (URL) -> Void

    /// - Parameters:
    ///   - edit: gets the bytes as read and their modification time; returns the new bytes, or
    ///     `nil` to leave the file alone. Called again when the file changed meanwhile, so
    ///     whatever it prepares (a backup) must be safe to prepare again.
    /// - Returns: `false` when `edit` left the file alone.
    @discardableResult
    static func rewrite(_ file: URL, hook: Hook? = nil, edit: (Data, FileTime) throws -> Data?) throws -> Bool {
        let target = resolved(file)
        let parent = target.deletingLastPathComponent()
        for _ in 0..<attempts {
            guard let before = FileFingerprint(of: target) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "it is no longer there"])
            }
            let data = try Data(contentsOf: target)
            // Appended to between the look and the read.
            guard Int64(data.count) == before.size, FileFingerprint(of: target) == before else { continue }
            guard let new = try edit(data, before.modificationTime) else { return false }

            let parentTime = FileSystem.modificationTime(of: parent)
            let staging = parent.appendingPathComponent(".domovy-index-\(UUID().uuidString)")
            defer {
                if FileSystem.itemExists(staging) { try? FileManager.default.removeItem(at: staging) }
                if let parentTime { try? FileSystem.setModificationTime(parentTime, of: parent) }
            }
            guard FileManager.default.createFile(atPath: staging.path, contents: new, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Could not create a file next to it."])
            }
            copyMetadata(from: target, to: staging)
            try FileSystem.setModificationTime(before.modificationTime, of: staging)
            hook?(file)
            guard FileFingerprint(of: target) == before else { continue }
            guard rename(staging.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return true
        }
        Log.executor.error("\(file.path, privacy: .private) kept changing while Domovy edited it")
        throw ExecutorError.indexKeptChanging(file)
    }

    /// The file a symlink points to, or `file` itself.
    static func resolved(_ file: URL) -> URL {
        guard let real = realpath(file.path, nil) else { return file }
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real))
    }

    /// Mode and extended attributes. Not the compression attributes: the new bytes are plain.
    private static func copyMetadata(from source: URL, to target: URL) {
        if let mode = FileSystem.posixPermissions(of: source) { chmod(target.path, mode_t(mode)) }
        let size = listxattr(source.path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return }
        var names = [CChar](repeating: 0, count: size)
        guard listxattr(source.path, &names, size, XATTR_NOFOLLOW) == size else { return }
        let skipped: Set<String> = ["com.apple.decmpfs", "com.apple.ResourceFork"]
        for name in names.split(separator: 0).map({ String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }) where !skipped.contains(name) {
            let length = getxattr(source.path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard length >= 0 else { continue }
            var value = [UInt8](repeating: 0, count: length)
            guard getxattr(source.path, name, &value, length, 0, XATTR_NOFOLLOW) == length else { continue }
            if setxattr(target.path, name, value, length, 0, XATTR_NOFOLLOW) != 0 {
                Log.executor.error("Could not keep an extended attribute of \(source.path, privacy: .private)")
            }
        }
    }
}
