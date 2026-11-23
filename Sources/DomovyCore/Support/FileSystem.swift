import Foundation

/// A file timestamp with full nanosecond precision, as APFS stores it.
public struct FileTime: Hashable, Codable, Sendable {
    public let seconds: Int64
    public let nanoseconds: Int64

    public var date: Date {
        Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanoseconds) / 1_000_000_000)
    }
}

/// Small file-system helpers shared by adapters and the executor.
enum FileSystem {
    /// Logical size of a file, or the sum of all files below a folder. Symlinks are not followed.
    static func size(of url: URL, fileManager: FileManager = .default) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isSymbolicLink == true { return 0 }
        if values.isDirectory == true {
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: []
            ) else { return 0 }
            var total: Int64 = 0
            for case let child as URL in enumerator {
                guard let v = try? child.resourceValues(forKeys: keys), v.isDirectory != true, v.isSymbolicLink != true else { continue }
                total += Int64(v.fileSize ?? 0)
            }
            return total
        }
        return Int64(values.fileSize ?? 0)
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    static func exists(_ url: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Nanosecond-exact modification time, so a rewrite can put back precisely what was there.
    /// `Date` and `FileManager.setAttributes` both lose sub-microsecond precision.
    static func modificationTime(of url: URL) -> FileTime? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return FileTime(seconds: Int64(info.st_mtimespec.tv_sec), nanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }

    /// Restores a modification time after a write. Retention sweeps key on this value.
    static func setModificationTime(_ time: FileTime, of url: URL) throws {
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: Int(time.seconds), tv_nsec: Int(time.nanoseconds))]
        guard utimensat(AT_FDCWD, url.path, &times, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func posixPermissions(of url: URL, fileManager: FileManager = .default) -> Int? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }

    /// Children of a directory, sorted by name. Empty when the directory is missing.
    static func children(of url: URL, fileManager: FileManager = .default) -> [URL] {
        let items = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        // Standardize so every URL we hand out uses the same form as the injected root.
        return (items ?? []).map(\.standardizedFileURL).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Path of `url` relative to `base`, or `nil` when it is not below `base`.
    static func relativePath(of url: URL, under base: URL) -> String? {
        let baseComponents = base.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= baseComponents.count,
              Array(components.prefix(baseComponents.count)) == baseComponents else { return nil }
        return components.dropFirst(baseComponents.count).joined(separator: "/")
    }
}
