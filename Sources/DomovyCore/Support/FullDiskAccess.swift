import Darwin
import Foundation

/// Full Disk Access: whether macOS lets Domovy into folders it protects (other apps' containers,
/// Mail, Safari), and calm wording for when it does not. Domovy works without it; a few agents
/// keep data in such folders (Warp's group container), and those are measured only with it.
public enum FullDiskAccess {
    public enum Status: Sendable, Equatable {
        case granted
        case denied
        /// No probe path exists on this Mac, so Domovy cannot tell.
        case unknown
    }

    /// Opens a few files only Full Disk Access can open, read-only, and closes them at once.
    /// Nothing is read. These locations never show a consent prompt; they are simply refused.
    /// - Parameter home: the real home folder. TCC is about this user, not a fixture home.
    public static func status(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Status {
        let probes = [
            "Library/Application Support/com.apple.TCC/TCC.db",
            "Library/Safari/Bookmarks.plist",
            "Library/Safari",
            "Library/Mail",
        ].map { home.appendingPathComponent($0).path }
        var sawDenial = false
        for path in probes {
            switch probe(path) {
            case .granted: return .granted
            case .denied: sawDenial = true
            case .unknown: continue
            }
        }
        return sawDenial ? .denied : .unknown
    }

    private static func probe(_ path: String) -> Status {
        var info = stat()
        guard lstat(path, &info) == 0 else { return isPermissionError(errno) ? .denied : .unknown }
        if (info.st_mode & S_IFMT) == S_IFDIR {
            guard let dir = opendir(path) else { return isPermissionError(errno) ? .denied : .unknown }
            closedir(dir)
            return .granted
        }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return isPermissionError(errno) ? .denied : .unknown }
        close(fd)
        return .granted
    }

    /// The pane in System Settings where the user turns it on.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")

    /// True when macOS refuses to look at `url` or into it: the path or its listing fails with
    /// "operation not permitted" or "permission denied". False when it does not exist.
    public static func isBlocked(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return isPermissionError(errno) }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        guard let dir = opendir(url.path) else { return isPermissionError(errno) }
        closedir(dir)
        return false
    }

    /// The note on a Disk row Domovy could not measure.
    public static let blockedNote = "macOS keeps this folder private, so Domovy could not measure it. Turn on Full Disk Access for Domovy in System Settings to include it."

    /// A user-facing line for a scan failure: a calm Full Disk Access note when macOS refused
    /// access, otherwise the error's own description.
    public static func explain(_ error: any Error, agent: AgentKind) -> String {
        if isPermissionError(error) {
            return "\(agent.displayName): macOS did not let Domovy read some of its files. Turning on Full Disk Access for Domovy in System Settings may help."
        }
        return error.localizedDescription
    }

    /// Whether an error is macOS refusing access (TCC or file permissions), however wrapped.
    public static func isPermissionError(_ error: any Error) -> Bool {
        if case AdapterError.unreadable(_, let reason) = error {
            return reason.localizedCaseInsensitiveContains("not permitted") || reason.localizedCaseInsensitiveContains("permission")
        }
        var current: NSError? = error as NSError
        while let ns = current {
            if ns.domain == NSCocoaErrorDomain, [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(ns.code) { return true }
            if ns.domain == NSPOSIXErrorDomain, isPermissionError(Int32(ns.code)) { return true }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    static func isPermissionError(_ code: Int32) -> Bool {
        code == EPERM || code == EACCES
    }
}
