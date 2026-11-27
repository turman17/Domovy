import Darwin
import Foundation

/// Open-file-handle check via libproc: `proc_listpids` + `PROC_PIDLISTFDS` +
/// `PROC_PIDFDVNODEPATHINFO`, plus memory-mapped files through the region path info
/// (`mmap` keeps a file in use after its descriptor closed: model weights, databases). Needs
/// no root; processes of other users cannot be inspected and are skipped, and so are processes
/// that exited meanwhile. Any failure to list processes, or not being able to inspect a single
/// running process of the current user (the only ones that can write to the user's agent
/// folders), reports the check as unavailable.
///
/// Enumerating every descriptor of every process costs tens of milliseconds, and a scan
/// asks once per session, so each snapshot is cached for a short moment. Mapped regions cost
/// more, so they are read only for large files or when the caller asks.
public actor LibprocOpenHandleChecker: OpenHandleChecker {
    /// Files at least this large are also looked for among mapped regions.
    static let mappedFileThreshold: Int64 = 8 << 20

    private let cacheLifetime: TimeInterval
    private var snapshot: [OpenHandleHolder]?
    private var snapshotTakenAt: Date = .distantPast
    private var mappedSnapshot: [OpenHandleHolder]?
    private var mappedSnapshotTakenAt: Date = .distantPast

    /// One checker for every adapter made with `init(home:)`, so a scan of all agents (they run
    /// side by side) takes one snapshot instead of one per agent. Listing and planning only:
    /// the executor takes its own (`OpenFileSnapshots`).
    public static let shared = LibprocOpenHandleChecker()

    /// - Parameter cacheLifetime: how long one process snapshot answers repeated calls.
    public init(cacheLifetime: TimeInterval = 1) {
        self.cacheLifetime = cacheLifetime
    }

    public func holders(of urls: [URL]) async -> [OpenHandleHolder]? {
        await holders(of: urls, includingMapped: urls.contains(where: Self.mayBeMapped))
    }

    public func holders(of urls: [URL], includingMapped: Bool) async -> [OpenHandleHolder]? {
        guard !urls.isEmpty else { return [] }
        if snapshot == nil || Date().timeIntervalSince(snapshotTakenAt) > cacheLifetime {
            snapshot = Self.takeSnapshot()
            snapshotTakenAt = Date()
        }
        guard let snapshot else { return nil }
        var matches = matchOpenPaths(snapshot, against: urls)
        guard includingMapped else { return matches }
        if mappedSnapshot == nil || Date().timeIntervalSince(mappedSnapshotTakenAt) > cacheLifetime {
            mappedSnapshot = Self.takeMappedSnapshot()
            mappedSnapshotTakenAt = Date()
        }
        guard let mappedSnapshot else { return nil }
        for holder in matchOpenPaths(mappedSnapshot, against: urls) where !matches.contains(holder) { matches.append(holder) }
        return matches
    }

    /// A large regular file: the kind a process maps instead of reading.
    static func mayBeMapped(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { return false }
        return Int64(values.fileSize ?? 0) >= mappedFileThreshold
    }

    /// Every process that holds one of `urls` open right now, mapped files included, without the
    /// cache; `nil` when that could not be checked. For the executor, right before it writes.
    static func currentHolders(of urls: [URL]) -> [OpenHandleHolder]? {
        guard !urls.isEmpty else { return [] }
        return currentSnapshot().map { matchOpenPaths($0, against: urls) }
    }

    /// Every open and every mapped regular file of the processes we may inspect, each holder
    /// once, without the cache; `nil` when either could not be read.
    static func currentSnapshot() -> [OpenHandleHolder]? {
        guard let snapshot = takeSnapshot(), let mapped = takeMappedSnapshot() else { return nil }
        var seen = Set(snapshot)
        return snapshot + mapped.filter { seen.insert($0).inserted }
    }

    // MARK: libproc

    /// Every regular-file vnode open by a process we are allowed to inspect, or `nil` when
    /// the process list itself could not be read.
    static func takeSnapshot() -> [OpenHandleHolder]? {
        guard let pids = listPIDs() else {
            Log.liveness.error("proc_listpids failed: \(String(cString: strerror(errno)), privacy: .public)")
            return nil
        }
        var holders: [OpenHandleHolder] = []
        var inspected = 0
        for pid in pids where pid > 0 {
            guard let fds = retryingStartingProcess(pid, { listFDs(of: pid) }) else {
                guard !isOwnRunningProcess(pid) else { return uninspectable(pid) }
                continue // another user's process, or gone
            }
            inspected += 1
            var name: String?
            for fd in fds where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                guard let path = vnodePath(pid: pid, fd: fd.proc_fd) else { continue }
                if name == nil { name = processName(of: pid) }
                holders.append(OpenHandleHolder(pid: pid, processName: name ?? "pid \(pid)", path: path))
            }
        }
        guard inspected > 0 else { return nil }
        return holders
    }

    /// Every file mapped into a process we are allowed to inspect, or `nil` when no process
    /// could be inspected at all.
    static func takeMappedSnapshot() -> [OpenHandleHolder]? {
        guard let pids = listPIDs() else {
            Log.liveness.error("proc_listpids failed: \(String(cString: strerror(errno)), privacy: .public)")
            return nil
        }
        let flavor = regionFlavor
        var holders: [OpenHandleHolder] = []
        var inspected = 0
        for pid in pids where pid > 0 {
            guard let paths = retryingStartingProcess(pid, { mappedPaths(of: pid, flavor: flavor) }) else {
                guard !isOwnRunningProcess(pid) else { return uninspectable(pid) }
                continue // another user's process, or gone
            }
            inspected += 1
            guard !paths.isEmpty else { continue }
            let name = processName(of: pid) ?? "pid \(pid)"
            holders += paths.map { OpenHandleHolder(pid: pid, processName: name, path: $0) }
        }
        guard inspected > 0 else {
            Log.liveness.error("No process could be inspected for mapped files")
            return nil
        }
        return holders
    }

    /// A process of the current user that is still running (not exiting, not a zombie).
    static func isOwnRunningProcess(_ pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_eproc.e_ucred.cr_uid == getuid() && info.kp_proc.p_stat != CChar(SZOMB) && info.kp_proc.p_flag & P_WEXIT == 0
    }

    /// A process of this user that is starting (between fork and exec) or exiting cannot be
    /// read for a few milliseconds. Asks again briefly before the caller treats it as
    /// uninspectable; another user's process or a gone one fails at once.
    static func retryingStartingProcess<T>(_ pid: pid_t, _ read: () -> T?) -> T? {
        if let value = read() { return value }
        for _ in 0..<5 {
            guard isOwnRunningProcess(pid) else { return nil }
            usleep(10_000)
            if let value = read() { return value }
        }
        return nil
    }

    private static func uninspectable(_ pid: pid_t) -> [OpenHandleHolder]? {
        Log.liveness.error("Could not inspect pid \(pid, privacy: .public), a process of this user; the open-file check is unavailable")
        return nil
    }

    /// `PROC_PIDREGIONPATHINFO2` (22, in xnu but not in the public header) returns only regions
    /// backed by a file, which makes a full scan about 15 times faster. If this macOS rejects
    /// it, the public `PROC_PIDREGIONPATHINFO` walks every region instead.
    static let regionFlavor: Int32 = {
        let fileBackedOnly: Int32 = 22
        var info = proc_regionwithpathinfo()
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        return proc_pidinfo(getpid(), fileBackedOnly, 0, &info, size) == size ? fileBackedOnly : PROC_PIDREGIONPATHINFO
    }()

    /// Paths of the files mapped into `pid`, or `nil` when it cannot be inspected. Each call
    /// returns the region at or after an address; the walk goes region by region.
    static func mappedPaths(of pid: pid_t, flavor: Int32) -> Set<String>? {
        var paths = Set<String>()
        var address: UInt64 = 0
        var inspected = false
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        while true {
            var info = proc_regionwithpathinfo()
            guard proc_pidinfo(pid, flavor, address, &info, size) == size else { break }
            inspected = true
            if (info.prp_vip.vip_vi.vi_stat.vst_mode & S_IFMT) == S_IFREG {
                let path = withUnsafePointer(to: &info.prp_vip.vip_path) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                if !path.isEmpty { paths.insert(path) }
            }
            let next = info.prp_prinfo.pri_address &+ info.prp_prinfo.pri_size
            guard next > address else { break }
            address = next
        }
        return inspected ? paths : nil
    }

    static func listPIDs() -> [pid_t]? {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return nil }
        // Leave headroom: processes may appear between the two calls.
        var buffer = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.stride + 64)
        let written = buffer.withUnsafeMutableBytes { raw in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, raw.baseAddress, Int32(raw.count))
        }
        guard written > 0 else { return nil }
        return Array(buffer.prefix(Int(written) / MemoryLayout<pid_t>.stride))
    }

    static func listFDs(of pid: pid_t) -> [proc_fdinfo]? {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return nil }
        var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / MemoryLayout<proc_fdinfo>.stride + 16)
        let written = buffer.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard written > 0 else { return nil }
        return Array(buffer.prefix(Int(written) / MemoryLayout<proc_fdinfo>.stride))
    }

    static func vnodePath(pid: pid_t, fd: Int32) -> String? {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        let written = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, pointer, size)
        }
        guard written == size else { return nil }
        // Only regular files matter; sockets, pipes and directories are not transcripts.
        guard (info.pvip.vip_vi.vi_stat.vst_mode & S_IFMT) == S_IFREG else { return nil }
        return withUnsafePointer(to: &info.pvip.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    static func processName(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let length = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
