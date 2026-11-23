import Foundation

/// One process as the kernel reports it. Never holds command-line arguments: those are read
/// on demand for classification only (`ProcessSource.arguments(of:)`) and then dropped.
public struct RawProcess: Hashable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    public let uid: UInt32
    /// The kernel's process name (`proc_name`), e.g. `claude`, `node`, `Claude Helper`.
    public let name: String
    /// `proc_pidpath`, when readable.
    public let executablePath: String?
    /// Start time in microseconds since 1970. With the pid it identifies the process: a pid
    /// reused by a new process has another start time.
    public let startMicros: UInt64
    /// Stopped by SIGSTOP (`SSTOP`).
    public let isStopped: Bool
    /// User plus system CPU time so far, in nanoseconds. `nil` for other users' processes.
    public let cpuNanos: UInt64?
    /// `phys_footprint`, the memory Activity Monitor shows. `nil` when not readable.
    public let footprintBytes: Int64?

    public init(pid: Int32, ppid: Int32, uid: UInt32, name: String, executablePath: String? = nil, startMicros: UInt64,
                isStopped: Bool = false, cpuNanos: UInt64? = nil, footprintBytes: Int64? = nil) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.name = name
        self.executablePath = executablePath
        self.startMicros = startMicros
        self.isStopped = isStopped
        self.cpuNanos = cpuNanos
        self.footprintBytes = footprintBytes
    }

    public var key: ProcessKey { ProcessKey(pid: pid, startMicros: startMicros) }
    public var startDate: Date { Date(timeIntervalSince1970: TimeInterval(startMicros) / 1_000_000) }
}

/// A pid together with its start time, so a reused pid is never mistaken for the old process.
public struct ProcessKey: Hashable, Codable, Sendable {
    public let pid: Int32
    public let startMicros: UInt64

    public init(pid: Int32, startMicros: UInt64) {
        self.pid = pid
        self.startMicros = startMicros
    }
}

/// Where process tables come from. The shipping implementation reads libproc and sysctl;
/// tests inject synthetic tables.
public protocol ProcessSource: Sendable {
    /// Every process, or `nil` when the process list could not be read.
    func snapshot() -> [RawProcess]?
    /// One process now, to check its identity right before a signal.
    func process(_ pid: Int32) -> RawProcess?
    /// Command-line arguments, for classification only. Never logged or shown: they can hold
    /// secrets. `nil` when not readable (another user's process).
    func arguments(of pid: Int32) -> [String]?
    /// Paths of the regular files `pid` holds open, `nil` when not readable.
    func openFiles(of pid: Int32) -> [String]?
    var currentUserID: UInt32 { get }
    var ownPID: Int32 { get }
}

/// A fixed table, for tests and previews.
public struct FixedProcessSource: ProcessSource {
    public var processes: [RawProcess]?
    public var argumentsByPID: [Int32: [String]]
    public var openFilesByPID: [Int32: [String]]
    public let currentUserID: UInt32
    public let ownPID: Int32

    public init(_ processes: [RawProcess]?, arguments: [Int32: [String]] = [:], openFiles: [Int32: [String]] = [:],
                currentUserID: UInt32 = 501, ownPID: Int32 = 99_999) {
        self.processes = processes
        argumentsByPID = arguments
        openFilesByPID = openFiles
        self.currentUserID = currentUserID
        self.ownPID = ownPID
    }

    public func snapshot() -> [RawProcess]? { processes }
    public func process(_ pid: Int32) -> RawProcess? { processes?.first { $0.pid == pid } }
    public func arguments(of pid: Int32) -> [String]? { argumentsByPID[pid] }
    public func openFiles(of pid: Int32) -> [String]? { openFilesByPID[pid] ?? [] }
}
