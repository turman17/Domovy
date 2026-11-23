import Foundation

/// Answers "does a process with this pid exist?". Agents leave liveness files behind after
/// a crash; a marker whose pid is gone is stale and must not make a session live.
public protocol ProcessProbe: Sendable {
    func isRunning(_ pid: Int32) -> Bool
}

/// `kill(pid, 0)`: no signal is sent. `ESRCH` means no such process; `EPERM` means it
/// exists but belongs to someone else, which still counts as running.
public struct KillProcessProbe: ProcessProbe {
    public init() {}

    public func isRunning(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

/// Fixed answers, for tests and previews.
public struct FixedProcessProbe: ProcessProbe {
    public let running: Set<Int32>

    public init(running: Set<Int32>) {
        self.running = running
    }

    public func isRunning(_ pid: Int32) -> Bool {
        running.contains(pid)
    }
}
