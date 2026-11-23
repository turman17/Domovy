import Darwin
import Foundation

/// Names an app by its process names, so a plan can refuse while the app runs
/// (CLAUDE.md safety rule 4: never write an app's index while it runs).
public struct ProcessMatcher: Hashable, Codable, Sendable {
    /// Shown to the user: "Codex is running".
    public let appName: String
    /// Exact process names, lowercased.
    public let names: Set<String>
    /// Name prefixes of helper processes, lowercased ("codex-").
    public let prefixes: [String]

    public init(appName: String, names: Set<String>, prefixes: [String] = []) {
        self.appName = appName
        self.names = names
        self.prefixes = prefixes
    }

    public func matches(_ processName: String) -> Bool {
        let name = processName.lowercased()
        return names.contains(name) || prefixes.contains { name.hasPrefix($0) }
    }
}

public struct RunningProcess: Hashable, Codable, Sendable {
    public let pid: Int32
    public let name: String

    public init(pid: Int32, name: String) {
        self.pid = pid
        self.name = name
    }
}

/// Lists running processes by name. The shipping implementation reads libproc; tests inject a fixed list.
public protocol RunningProcessLister: Sendable {
    /// Matching processes, or `nil` when the process list could not be read.
    func running(matching matcher: ProcessMatcher) -> [RunningProcess]?
}

extension RunningProcessLister {
    /// User-explainable reasons why `matchers` block a change. Unsure counts as blocked.
    func blockingReasons(_ matchers: [ProcessMatcher]) -> [String] {
        matchers.compactMap { matcher in
            guard let found = running(matching: matcher) else {
                return "Domovy could not check whether \(matcher.appName) is running, so it changes nothing."
            }
            guard !found.isEmpty else { return nil }
            let pids = found.prefix(3).map { "\($0.name), pid \($0.pid)" }.joined(separator: "; ")
            return "\(matcher.appName) is running (\(pids)). Quit \(matcher.appName) first; it may rewrite its index while this runs."
        }
    }
}

/// `proc_listpids` + `proc_name`. Names of other users' processes are readable too.
public struct LibprocProcessLister: RunningProcessLister {
    public init() {}

    public func running(matching matcher: ProcessMatcher) -> [RunningProcess]? {
        guard let pids = LibprocOpenHandleChecker.listPIDs() else { return nil }
        let me = getpid()
        return pids.compactMap { pid in
            guard pid > 0, pid != me, let name = LibprocOpenHandleChecker.processName(of: pid), matcher.matches(name) else { return nil }
            return RunningProcess(pid: pid, name: name)
        }
    }
}

/// Fixed answers, for tests and previews.
public struct FixedProcessLister: RunningProcessLister {
    public let processes: [RunningProcess]?

    public init(_ processes: [RunningProcess]?) {
        self.processes = processes
    }

    public func running(matching matcher: ProcessMatcher) -> [RunningProcess]? {
        processes?.filter { matcher.matches($0.name) }
    }
}
