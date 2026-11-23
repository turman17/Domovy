import Darwin
import Foundation

/// What Domovy can do to a process tree. Never automatic: each one is shown and confirmed.
public enum ProcessAction: String, Codable, Sendable, CaseIterable {
    /// SIGSTOP: the processes keep their memory but stop using the CPU. Reversible.
    case freeze
    /// SIGCONT.
    case resume
    /// SIGTERM: asks the processes to exit. Orphans only.
    case quit
    /// SIGKILL, offered only after a quit left processes running.
    case forceQuit

    var signal: Int32 {
        switch self {
        case .freeze: SIGSTOP
        case .resume: SIGCONT
        case .quit: SIGTERM
        case .forceQuit: SIGKILL
        }
    }

    public var title: String {
        switch self {
        case .freeze: "Freeze"
        case .resume: "Resume"
        case .quit: "Quit"
        case .forceQuit: "Force Quit"
        }
    }

    var pastTense: String {
        switch self {
        case .freeze: "Froze"
        case .resume: "Resumed"
        case .quit: "Asked to quit"
        case .forceQuit: "Force quit"
        }
    }
}

/// One process a plan signals, identified by pid and start time.
public struct ProcessTarget: Hashable, Codable, Sendable {
    public let key: ProcessKey
    public let name: String
    public let footprintBytes: Int64?

    public var pid: Int32 { key.pid }

    init(_ node: ProcessNode) {
        key = node.key
        name = node.name
        footprintBytes = node.footprintBytes
    }
}

/// Exactly which processes an action signals, in order, or why it is refused.
public struct ProcessActionPlan: Sendable {
    public let action: ProcessAction
    /// The process the user picked, e.g. "node @playwright/mcp".
    public let rootName: String
    public let agent: AgentKind?
    public let targets: [ProcessTarget]
    /// Processes below it that are not signaled: part of macOS (a shell), another user's, or Domovy.
    public let leftAlone: [ProcessTarget]
    /// User-explainable reasons the plan cannot run. Empty when it can.
    public let refusals: [String]
    /// What to do instead, e.g. "Freeze it instead."
    public let suggestion: ProcessAction?

    public var canExecute: Bool { refusals.isEmpty && !targets.isEmpty }
    public var totalBytes: Int64 { targets.reduce(0) { $0 + ($1.footprintBytes ?? 0) } }

    /// Plain words: what happens and whether it can be undone.
    public var summary: String {
        guard refusals.isEmpty else { return refusals.joined(separator: " ") }
        let others = targets.count - 1
        let what = "\(rootName) (pid \(targets.first?.pid ?? 0))" + (others > 0 ? " and \(others) \(others == 1 ? "process" : "processes") it started" : "")
        let size = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .memory)
        let n = leftAlone.count
        let left = n == 0 ? "" : " \(n) \(n == 1 ? "process" : "processes") below it (\(leftAlone.prefix(3).map(\.name).joined(separator: ", "))) \(n == 1 ? "is" : "are") left alone: part of macOS, or Domovy itself."
        return describe(what: what, size: size) + left
    }

    private func describe(what: String, size: String) -> String {
        switch action {
        case .freeze:
            return "Pauses \(what). They keep their \(size) of memory but use no CPU until you resume them. Nothing is lost; Resume undoes this."
        case .resume:
            return "Lets \(what) run again."
        case .quit:
            return "Asks \(what) to exit (SIGTERM), freeing about \(size). Unsaved work in them is lost. If any are still running after a few seconds, Domovy says so and offers Force Quit."
        case .forceQuit:
            return "Ends \(what) at once (SIGKILL). They get no chance to clean up. This cannot be undone."
        }
    }
}

/// What a signal round did.
public struct ProcessActionResult: Sendable {
    public let action: ProcessAction
    public let signaled: [ProcessTarget]
    /// After a quit: processes still running when the wait ended.
    public let stillRunning: [ProcessTarget]
    /// Targets not signaled, with the reason (exited already, pid reused, refused by the kernel).
    public let skipped: [String]

    public var summary: String {
        var parts: [String] = []
        let n = signaled.count
        if n > 0 { parts.append("\(action.pastTense) \(n) \(n == 1 ? "process" : "processes").") }
        if !stillRunning.isEmpty {
            let m = stillRunning.count
            parts.append("\(m) \(m == 1 ? "is" : "are") still running: \(stillRunning.prefix(3).map { "\($0.name) (pid \($0.pid))" }.joined(separator: ", ")).")
        } else if action == .quit || action == .forceQuit, n > 0 {
            parts.append("All of them have exited.")
        }
        parts += skipped
        return parts.isEmpty ? "Nothing was signaled." : parts.joined(separator: " ")
    }
}

public enum ProcessActionError: Error, LocalizedError, Sendable {
    case notFound(Int32)
    case refused([String])
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .notFound(let pid): "pid \(pid) is not an agent process Domovy knows about. Run `domo ps` to see them."
        case .refused(let reasons): reasons.joined(separator: " ")
        case .unreadable: "Domovy could not read the process list, so it signals nothing."
        }
    }
}

/// Sends signals. Tests record them instead.
public protocol ProcessSignaler: Sendable {
    /// `nil` on success, otherwise the errno.
    func send(_ signal: Int32, to pid: Int32) -> Int32?
}

public struct KillSignaler: ProcessSignaler {
    public init() {}

    public func send(_ signal: Int32, to pid: Int32) -> Int32? {
        kill(pid, signal) == 0 ? nil : errno
    }
}
