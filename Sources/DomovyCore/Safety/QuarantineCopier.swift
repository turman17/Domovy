import Darwin
import Foundation

/// Keeps a copy of what a tool is about to delete for good (`ollama rm`, `hf cache rm`,
/// `codex delete`), so undo can put it back (safety rule 1). An APFS clone costs almost no
/// space while the original exists; when cloning is not possible (another volume, not APFS)
/// a full copy is made instead. If neither works, the command does not run.
public struct QuarantineCopier: Sendable {
    public enum Method: String, Codable, Sendable {
        case clone
        case copy
    }

    let clone: @Sendable (_ source: URL, _ target: URL) throws -> Void
    let copy: @Sendable (_ source: URL, _ target: URL) throws -> Void

    /// Tests pass strategies that fail on purpose.
    public init(
        clone: @escaping @Sendable (_ source: URL, _ target: URL) throws -> Void,
        copy: @escaping @Sendable (_ source: URL, _ target: URL) throws -> Void
    ) {
        self.clone = clone
        self.copy = copy
    }

    public static let system = QuarantineCopier(clone: cloneItem, copy: copyItem)

    /// Clones `source` to `target`, else copies it. Throws when neither worked; nothing is
    /// left at `target` then.
    func keep(_ source: URL, at target: URL) throws -> Method {
        do {
            try clone(source, target)
            return .clone
        } catch let cloneError {
            try? FileManager.default.removeItem(at: target)
            Log.executor.info("Could not clone \(source.path, privacy: .private): \(cloneError.localizedDescription, privacy: .public); copying instead")
            do {
                try copy(source, target)
                return .copy
            } catch {
                try? FileManager.default.removeItem(at: target)
                throw error
            }
        }
    }

    /// `clonefile(2)` clones a file or a whole folder; symlinks stay symlinks.
    static func cloneItem(_ source: URL, _ target: URL) throws {
        guard clonefile(source.path, target.path, UInt32(CLONE_NOFOLLOW)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// A full copy, only when the volume has room for it.
    static func copyItem(_ source: URL, _ target: URL) throws {
        let needed = DiskUsage.measure(source).allocated
        let folder = target.deletingLastPathComponent()
        if let available = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           available < needed {
            throw CocoaError(.fileWriteOutOfSpace, userInfo: [NSLocalizedDescriptionKey: "there is not enough free space for a full copy (\(CleanupPlan.bytes(needed)))"])
        }
        try FileManager.default.copyItem(at: source, to: target)
    }
}

/// Mode and nanosecond modification time of one item of a kept copy, recorded before the tool
/// ran, so undo puts back exactly what was there (safety rule 5).
public struct KeptFileMetadata: Codable, Sendable, Hashable {
    /// Below the kept item; empty for the item itself.
    public let path: String
    public let mode: Int?
    public let modificationTime: FileTime?
    public let isSymlink: Bool

    /// The item and, for a folder, everything below it. Symlinks are recorded, not followed.
    static func record(_ url: URL) -> [KeptFileMetadata] {
        var paths = [""]
        if FileSystem.isDirectory(url), let all = FileManager.default.enumerator(atPath: url.path) {
            for case let path as String in all { paths.append(path) }
        }
        return paths.compactMap { path in
            let item = path.isEmpty ? url : url.appendingPathComponent(path)
            var info = stat()
            guard lstat(item.path, &info) == 0 else { return nil }
            return KeptFileMetadata(
                path: path,
                mode: Int(info.st_mode & 0o7777),
                modificationTime: FileTime(seconds: Int64(info.st_mtimespec.tv_sec), nanoseconds: Int64(info.st_mtimespec.tv_nsec)),
                isSymlink: (info.st_mode & S_IFMT) == S_IFLNK
            )
        }
    }

    /// Puts modes and times back below `root`, deepest first so a folder's time sticks.
    static func apply(_ items: [KeptFileMetadata], to root: URL) {
        for item in items.sorted(by: { $0.path.split(separator: "/").count > $1.path.split(separator: "/").count }) {
            let url = item.path.isEmpty ? root : root.appendingPathComponent(item.path)
            if !item.isSymlink, let mode = item.mode, chmod(url.path, mode_t(mode)) != 0 {
                Log.executor.error("Could not restore the mode of \(url.path, privacy: .private)")
            }
            if let time = item.modificationTime {
                do { try FileSystem.setModificationTime(time, of: url) } catch {
                    Log.executor.error("Could not restore the modification time of \(url.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}

extension FileSystem {
    /// True for a file, folder or symlink, even a dangling one.
    static func itemExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}
