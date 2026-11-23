import Darwin
import Foundation

/// Plans and sends Freeze, Resume, Quit and Force Quit. Refuses system processes, other users'
/// processes, Domovy and the processes it runs inside, and quitting anything but orphans: an
/// agent may have a live session (safety rule 2), so it is offered Freeze instead. Right before
/// each signal the process is read again; one that exited or whose pid was reused is skipped.
public struct ProcessController: Sendable {
    let source: any ProcessSource
    let signaler: any ProcessSignaler
    let log: ProcessActionLog?

    public init(source: any ProcessSource = LibprocProcessSource(), signaler: any ProcessSignaler = KillSignaler(), log: ProcessActionLog?) {
        self.source = source
        self.signaler = signaler
        self.log = log
    }

    /// The plan for `action` on `pid` and everything it started, as the report shows them.
    public func plan(_ action: ProcessAction, pid: Int32, in report: ProcessReport) throws -> ProcessActionPlan {
        guard let node = report.node(pid: pid), let tree = report.tree(containing: pid) else { throw ProcessActionError.notFound(pid) }
        var refusals = node.refusal.map { [$0] } ?? []
        var suggestion: ProcessAction?
        if action == .quit || action == .forceQuit, !tree.isOrphanTree {
            let agent = node.agent?.displayName ?? "its agent"
            refusals.insert(node.kind == .agent
                ? "\(node.name) is the agent itself and may have a live session. Domovy never quits an agent; freeze it instead."
                : "\(node.name) still belongs to \(agent), which may need it for a live session. Freeze it instead, or quit \(agent) yourself.", at: 0)
            suggestion = .freeze
        }
        // Below the chosen process, macOS's own tools (a shell), other users' processes and
        // Domovy itself are left alone rather than blocking the rest.
        let subtree = [node] + node.children.flatMap(\.subtree)
        let included = subtree.filter { $0.key == node.key || $0.refusal == nil }
        let left = subtree.filter { $0.key != node.key && $0.refusal != nil }
        if action == .resume, !included.contains(where: \.isFrozen) {
            refusals.append("\(node.name) is not frozen.")
        }
        // Freeze parents first so they cannot restart what was stopped; everything else children first.
        let ordered = action == .freeze ? included : included.reversed()
        return ProcessActionPlan(
            action: action, rootName: node.name, agent: node.agent, targets: ordered.map(ProcessTarget.init),
            leftAlone: left.map(ProcessTarget.init), refusals: refusals, suggestion: suggestion
        )
    }

    /// Force Quit for what a quit left running. Built only from a quit's result.
    public func forceQuitPlan(after result: ProcessActionResult, of quit: ProcessActionPlan) -> ProcessActionPlan {
        ProcessActionPlan(action: .forceQuit, rootName: quit.rootName, agent: quit.agent, targets: result.stillRunning, leftAlone: [],
                          refusals: result.stillRunning.isEmpty ? ["Nothing is left running."] : [], suggestion: nil)
    }

    /// Sends the plan's signal to each target still the same process. A quit then waits up to
    /// `timeout` for them to exit and reports the ones still running.
    public func execute(_ plan: ProcessActionPlan, timeout: TimeInterval = 3) async throws -> ProcessActionResult {
        guard plan.canExecute else { throw ProcessActionError.refused(plan.refusals) }
        let me = source.currentUserID
        var signaled: [ProcessTarget] = []
        var skipped: [String] = []
        for target in plan.targets {
            guard target.pid > 1, target.pid != source.ownPID else { continue }
            guard let current = source.process(target.pid), current.startMicros == target.key.startMicros else {
                skipped.append("\(target.name) (pid \(target.pid)) had already exited.")
                continue
            }
            guard current.uid == me, !ProcessClassifier.isSystem(current) else {
                skipped.append("\(target.name) (pid \(target.pid)) is not yours to signal.")
                continue
            }
            if let error = signaler.send(plan.action.signal, to: target.pid) {
                skipped.append("\(target.name) (pid \(target.pid)) could not be signaled: \(String(cString: strerror(error))).")
                continue
            }
            // A frozen process handles SIGTERM only once it runs again.
            if plan.action == .quit, current.isStopped { _ = signaler.send(SIGCONT, to: target.pid) }
            signaled.append(target)
        }
        Log.processes.info("\(plan.action.rawValue, privacy: .public): signaled \(signaled.count, privacy: .public), skipped \(skipped.count, privacy: .public)")

        var stillRunning: [ProcessTarget] = []
        if plan.action == .quit || plan.action == .forceQuit {
            let deadline = Date().addingTimeInterval(plan.action == .quit ? timeout : 1)
            stillRunning = signaled
            while !stillRunning.isEmpty, Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
                stillRunning = stillRunning.filter(isAlive)
            }
        }
        let result = ProcessActionResult(action: plan.action, signaled: signaled, stillRunning: stillRunning, skipped: skipped)
        log?.append(ProcessActionRecord(plan: plan, result: result))
        return result
    }

    /// Still the same process (same start time). Exited processes awaiting their parent
    /// (zombies) are not reported by the source.
    func isAlive(_ target: ProcessTarget) -> Bool {
        source.process(target.pid)?.startMicros == target.key.startMicros
    }
}
