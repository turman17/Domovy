import Darwin
import Foundation

/// Seam for "which process is working in this folder": the current directory of every process
/// Domovy may inspect. A shell, a dev server or an agent sitting in a checkout holds no file
/// open there, so the open-file check alone misses it.
public protocol WorkingDirectoryLister: Sendable {
    /// One holder per process, `path` its current directory; `nil` when the list could not be read.
    func workingDirectories() -> [OpenHandleHolder]?
}

extension WorkingDirectoryLister {
    /// Processes working in one of `urls` or below it; `nil` when that could not be checked.
    func holders(in urls: [URL]) -> [OpenHandleHolder]? {
        guard !urls.isEmpty else { return [] }
        return workingDirectories().map { matchOpenPaths($0, against: urls) }
    }
}

/// `proc_pidinfo(PROC_PIDVNODEPATHINFO)`. Processes of other users cannot be inspected and are
/// skipped, like in `LibprocOpenHandleChecker`; Domovy's own process is left out.
public struct LibprocWorkingDirectoryLister: WorkingDirectoryLister {
    public init() {}

    public func workingDirectories() -> [OpenHandleHolder]? {
        guard let pids = LibprocOpenHandleChecker.listPIDs() else { return nil }
        let me = getpid()
        var holders: [OpenHandleHolder] = []
        for pid in pids where pid > 0 && pid != me {
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { continue }
            let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard !path.isEmpty, path != "/" else { continue }
            let name = LibprocOpenHandleChecker.processName(of: pid) ?? "pid \(pid)"
            holders.append(OpenHandleHolder(pid: pid, processName: name, path: path))
        }
        return holders
    }
}

/// Fixed answers, for tests and custom homes.
public struct FixedWorkingDirectoryLister: WorkingDirectoryLister {
    public let holders: [OpenHandleHolder]?

    public init(_ holders: [OpenHandleHolder]? = []) {
        self.holders = holders
    }

    public func workingDirectories() -> [OpenHandleHolder]? { holders }
}
