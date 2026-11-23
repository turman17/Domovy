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
    /// Exact process names matched case-sensitively, for apps whose name differs from
    /// another tool's only by case (the `Claude` desktop app versus the `claude` CLI).
    public let exactNames: Set<String>
    /// When set, a matching process blocks only while it holds a file open below this folder.
    /// A daemon that serves another home (the ChatGPT app's codex app-server) then does not block.
    public let scope: URL?
    /// What the user should do, e.g. "Quit the ChatGPT app or Codex to change this session."
    public let quitAdvice: String?

    public init(appName: String, names: Set<String>, prefixes: [String] = [], exactNames: Set<String> = [], scope: URL? = nil, quitAdvice: String? = nil) {
        self.appName = appName
        self.names = names
        self.prefixes = prefixes
        self.exactNames = exactNames
        self.scope = scope?.standardizedFileURL
        self.quitAdvice = quitAdvice
    }

    public func matches(_ processName: String) -> Bool {
        if exactNames.contains(processName) { return true }
        let name = processName.lowercased()
        return names.contains(name) || prefixes.contains { name.hasPrefix($0) }
    }
}

extension ProcessMatcher {
    private enum CodingKeys: String, CodingKey {
        case appName, names, prefixes, exactNames, scope, quitAdvice
    }

    /// Undo entries written before `exactNames` existed decode with none.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            appName: try c.decode(String.self, forKey: .appName),
            names: try c.decode(Set<String>.self, forKey: .names),
            prefixes: try c.decodeIfPresent([String].self, forKey: .prefixes) ?? [],
            exactNames: try c.decodeIfPresent(Set<String>.self, forKey: .exactNames) ?? [],
            scope: try c.decodeIfPresent(URL.self, forKey: .scope),
            quitAdvice: try c.decodeIfPresent(String.self, forKey: .quitAdvice)
        )
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
    /// Paths of the regular files `pid` holds open: empty when it holds none or has exited,
    /// `nil` when they could not be read.
    func openFiles(of pid: Int32) -> [String]?
}

extension RunningProcessLister {
    /// User-explainable reasons why `matchers` block a change. Unsure counts as blocked.
    func blockingReasons(_ matchers: [ProcessMatcher]) -> [String] {
        matchers.compactMap { matcher in
            guard let found = running(matching: matcher) else {
                return "Domovy could not check whether \(matcher.appName) is running, so it changes nothing."
            }
            guard !found.isEmpty else { return nil }
            guard let scope = matcher.scope else {
                let pids = found.prefix(3).map { "\($0.name), pid \($0.pid)" }.joined(separator: "; ")
                let advice = matcher.quitAdvice ?? "Quit \(matcher.appName) first; it may rewrite its index while this runs."
                return "\(matcher.appName) is running (\(pids)). \(advice)"
            }
            return scopedReason(matcher, scope: scope, found: found)
        }
    }

    /// Blocks only for a process that has a file open below `scope`, or one whose open files
    /// cannot be read (unsure counts as blocked).
    private func scopedReason(_ matcher: ProcessMatcher, scope: URL, found: [RunningProcess]) -> String? {
        let place = (scope.path as NSString).abbreviatingWithTildeInPath
        let advice = matcher.quitAdvice ?? "Quit \(matcher.appName) first."
        var unreadable: RunningProcess?
        for process in found {
            guard let paths = openFiles(of: process.pid) else {
                unreadable = unreadable ?? process
                continue
            }
            let holders = paths.map { OpenHandleHolder(pid: process.pid, processName: process.name, path: $0) }
            if !matchOpenPaths(holders, against: [scope]).isEmpty {
                return "\(matcher.appName) is using \(place) (pid \(process.pid)). \(advice)"
            }
        }
        guard let unreadable else { return nil }
        return "Domovy could not see which files \(unreadable.name) (pid \(unreadable.pid)) has open, so it cannot tell whether \(matcher.appName) is using \(place). \(advice)"
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

    public func openFiles(of pid: Int32) -> [String]? {
        guard let fds = LibprocOpenHandleChecker.listFDs(of: pid) else {
            // Gone since it was listed: it holds nothing. Still there: we could not look.
            return KillProcessProbe().isRunning(pid) ? nil : []
        }
        return fds.filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) }
            .compactMap { LibprocOpenHandleChecker.vnodePath(pid: pid, fd: $0.proc_fd) }
    }
}

/// Fixed answers, for tests and previews.
public struct FixedProcessLister: RunningProcessLister {
    public let processes: [RunningProcess]?
    /// Open files per pid; a pid not listed holds nothing open.
    public let openFiles: [Int32: [String]]
    /// Pids whose open files cannot be read.
    public let unreadable: Set<Int32>

    public init(_ processes: [RunningProcess]?, openFiles: [Int32: [String]] = [:], unreadable: Set<Int32> = []) {
        self.processes = processes
        self.openFiles = openFiles
        self.unreadable = unreadable
    }

    public func running(matching matcher: ProcessMatcher) -> [RunningProcess]? {
        processes?.filter { matcher.matches($0.name) }
    }

    public func openFiles(of pid: Int32) -> [String]? {
        unreadable.contains(pid) ? nil : openFiles[pid] ?? []
    }
}
