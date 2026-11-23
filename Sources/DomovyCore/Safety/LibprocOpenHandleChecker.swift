import Darwin
import Foundation

/// Open-file-handle check via libproc: `proc_listpids` + `PROC_PIDLISTFDS` +
/// `PROC_PIDFDVNODEPATHINFO`. Needs no root; processes of other users cannot be
/// inspected and are skipped. Any failure to list processes reports the check as unavailable.
///
/// Enumerating every descriptor of every process costs tens of milliseconds, and a scan
/// asks once per session, so the snapshot is cached for a short moment.
public actor LibprocOpenHandleChecker: OpenHandleChecker {
    private let cacheLifetime: TimeInterval
    private var snapshot: [OpenHandleHolder]?
    private var snapshotTakenAt: Date = .distantPast

    /// - Parameter cacheLifetime: how long one process snapshot answers repeated calls.
    public init(cacheLifetime: TimeInterval = 1) {
        self.cacheLifetime = cacheLifetime
    }

    public func holders(of urls: [URL]) async -> [OpenHandleHolder]? {
        guard !urls.isEmpty else { return [] }
        if snapshot == nil || Date().timeIntervalSince(snapshotTakenAt) > cacheLifetime {
            snapshot = Self.takeSnapshot()
            snapshotTakenAt = Date()
        }
        guard let snapshot else { return nil }
        return matchOpenPaths(snapshot, against: urls)
    }

    // MARK: libproc

    /// Every regular-file vnode open by a process we are allowed to inspect, or `nil` when
    /// the process list itself could not be read.
    private static func takeSnapshot() -> [OpenHandleHolder]? {
        guard let pids = listPIDs() else {
            Log.liveness.error("proc_listpids failed: \(String(cString: strerror(errno)), privacy: .public)")
            return nil
        }
        var holders: [OpenHandleHolder] = []
        var inspected = 0
        for pid in pids where pid > 0 {
            guard let fds = listFDs(of: pid) else { continue } // other user's process, or gone
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

    private static func listFDs(of pid: pid_t) -> [proc_fdinfo]? {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return nil }
        var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / MemoryLayout<proc_fdinfo>.stride + 16)
        let written = buffer.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard written > 0 else { return nil }
        return Array(buffer.prefix(Int(written) / MemoryLayout<proc_fdinfo>.stride))
    }

    private static func vnodePath(pid: pid_t, fd: Int32) -> String? {
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
