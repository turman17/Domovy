import Darwin
import Foundation

/// Reads the process table with libproc (`proc_listpids`, `PROC_PIDTBSDINFO`, `proc_pidpath`,
/// `proc_pid_rusage`) and arguments with `sysctl(KERN_PROCARGS2)`. Nothing is shelled out.
/// Other users' processes appear with their names and parents but without memory or CPU.
public struct LibprocProcessSource: ProcessSource {
    public init() {}

    public var currentUserID: UInt32 { getuid() }
    public var ownPID: Int32 { getpid() }

    public func snapshot() -> [RawProcess]? {
        guard let pids = LibprocOpenHandleChecker.listPIDs() else {
            Log.processes.error("proc_listpids failed: \(String(cString: strerror(errno)), privacy: .public)")
            return nil
        }
        return pids.filter { $0 > 0 }.compactMap(process)
    }

    public func process(_ pid: Int32) -> RawProcess? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        // A zombie has exited and only waits for its parent to collect it: not running.
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status != UInt32(SZOMB) else { return nil }
        let name = LibprocOpenHandleChecker.processName(of: pid) ?? Self.comm(&info)
        let usage = Self.usage(of: pid)
        return RawProcess(
            pid: pid, ppid: Int32(bitPattern: info.pbi_ppid), uid: info.pbi_uid, name: name,
            executablePath: Self.path(of: pid),
            startMicros: info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec,
            isStopped: info.pbi_status == UInt32(SSTOP),
            cpuNanos: usage?.cpu, footprintBytes: usage?.footprint
        )
    }

    public func arguments(of pid: Int32) -> [String]? {
        Self.arguments(of: pid)
    }

    public func openFiles(of pid: Int32) -> [String]? {
        LibprocProcessLister().openFiles(of: pid)
    }

    // MARK: libproc

    private static func comm(_ info: inout proc_bsdinfo) -> String {
        withUnsafePointer(to: &info.pbi_comm) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
    }

    private static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let length = buffer.firstIndex(of: 0) ?? buffer.count
        let path = String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.isEmpty ? nil : path
    }

    /// CPU time in nanoseconds and the physical footprint. On Apple silicon the rusage times
    /// are Mach absolute time units, converted with the timebase.
    private static func usage(of pid: pid_t) -> (cpu: UInt64, footprint: Int64)? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard result == 0 else { return nil }
        let ticks = info.ri_user_time &+ info.ri_system_time
        let cpu = ticks.multipliedReportingOverflow(by: UInt64(timebase.numer)).partialValue / UInt64(max(1, timebase.denom))
        return (cpu, Int64(clamping: info.ri_phys_footprint))
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// `KERN_PROCARGS2`: argc, the executable path, padding, then argv. Only the caller's own
    /// processes are readable.
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 } // executable path
        while index < size, buffer[index] == 0 { index += 1 } // padding
        var arguments: [String] = []
        while arguments.count < Int(argc), index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}
