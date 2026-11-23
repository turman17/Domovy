import Foundation

/// Result of asking "is anything using this session right now?".
/// A session counts as live when any signal says so. When a signal could not be
/// evaluated the result says so, and callers that are unsure must refuse.
public struct LiveCheckResult: Hashable, Codable, Sendable {
    public enum OpenHandleStatus: String, Codable, Sendable {
        /// Open file handles were enumerated and none point at the session.
        case clear
        /// A process holds a file of the session open.
        case open
        /// The handle check could not run (see `OpenHandleChecker`).
        case unavailable
    }

    public let isLive: Bool
    /// User-explainable reasons, one per signal that fired.
    public let reasons: [String]
    /// Which signals were consulted ("sessions/*.json", "daemon/roster.json", ...).
    public let checkedSignals: [String]
    public let openHandles: OpenHandleStatus

    public init(isLive: Bool, reasons: [String], checkedSignals: [String], openHandles: OpenHandleStatus) {
        self.isLive = isLive
        self.reasons = reasons
        self.checkedSignals = checkedSignals
        self.openHandles = openHandles
    }

    public static let notLive = LiveCheckResult(isLive: false, reasons: [], checkedSignals: [], openHandles: .unavailable)
}

/// A process that holds a file of a session open.
public struct OpenHandleHolder: Hashable, Codable, Sendable {
    public let pid: Int32
    public let processName: String
    /// The open path, as reported by the kernel.
    public let path: String

    public init(pid: Int32, processName: String, path: String) {
        self.pid = pid
        self.processName = processName
        self.path = path
    }
}

/// Seam for the open-file-handle check. The shipping implementation is
/// `LibprocOpenHandleChecker`; tests inject a stub.
public protocol OpenHandleChecker: Sendable {
    /// Processes holding one of `urls` (or something below them) open, or `nil` when the
    /// check could not run at all. An empty array means "checked, nothing open".
    func holders(of urls: [URL]) async -> [OpenHandleHolder]?
    /// Also files mapped into memory (`mmap`), which stay in use after their descriptor
    /// closed. Costs more; asked for before deleting model files and databases.
    func holders(of urls: [URL], includingMapped: Bool) async -> [OpenHandleHolder]?
}

extension OpenHandleChecker {
    /// Checkers that cannot see mappings answer with open descriptors only.
    public func holders(of urls: [URL], includingMapped: Bool) async -> [OpenHandleHolder]? {
        await holders(of: urls)
    }
}

/// Reports the check as unavailable. Adapters then rely on the agents' own liveness files.
public struct UnavailableOpenHandleChecker: OpenHandleChecker {
    public init() {}

    public func holders(of urls: [URL]) async -> [OpenHandleHolder]? {
        nil
    }
}

/// Matches a URL list against a snapshot of open paths: equal, or below a folder in the list.
/// The kernel reports real paths (`/private/var/...`, where Foundation keeps `/var/...`),
/// so each URL is matched both as given and through `realpath`.
func matchOpenPaths(_ holders: [OpenHandleHolder], against urls: [URL]) -> [OpenHandleHolder] {
    var paths = Set<String>()
    for url in urls {
        let path = url.standardizedFileURL.path
        paths.insert(path)
        if let real = realpath(path, nil) {
            paths.insert(String(cString: real))
            free(real)
        }
    }
    return holders.filter { holder in
        paths.contains { holder.path == $0 || holder.path.hasPrefix($0 + "/") }
    }
}
