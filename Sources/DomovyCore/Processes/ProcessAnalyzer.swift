import Foundation

/// Builds a `ProcessReport` from one process table: agent trees, likely MCP servers, orphans,
/// CPU since the previous sample, and memory growth. Pure apart from asking the source for
/// arguments and open files, so tests run it on synthetic tables.
struct ProcessAnalyzer {
    let source: any ProcessSource
    let sessions: ProcessSessionResolver?

    struct Input {
        var processes: [RawProcess]
        /// CPU time per process at the previous sample, and how long ago that was.
        var previousCPU: [ProcessKey: UInt64] = [:]
        var elapsed: TimeInterval = 0
        var history: MemoryHistory = MemoryHistory(policy: .standard)
        /// Processes seen in an agent's tree earlier, so they are recognised once orphaned.
        var remembered: [ProcessKey: AgentKind] = [:]
        /// Herdr pane shells, so each agent tree is labelled with its workspace and pane.
        var herdr: HerdrProcessMap?
        var now = Date()
    }

    struct Output {
        let report: ProcessReport
        /// Every process now in an agent tree, with its agent, for the next `remembered`.
        let members: [ProcessKey: AgentKind]
    }

    /// Arguments are read at most once per process and only when classification needs them.
    private final class Arguments {
        let source: any ProcessSource
        var cache: [Int32: [String]?] = [:]
        init(source: any ProcessSource) { self.source = source }

        func of(_ pid: Int32) -> [String]? {
            if let cached = cache[pid] { return cached }
            let value = source.arguments(of: pid)
            cache[pid] = value
            return value
        }
    }

    func analyze(_ input: Input) -> Output {
        let table = Dictionary(input.processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let arguments = Arguments(source: source)
        var agentOf: [Int32: AgentKind] = [:]
        for process in input.processes {
            if let agent = ProcessClassifier.agent(of: process, arguments: { arguments.of(process.pid) }) { agentOf[process.pid] = agent }
        }
        var children: [Int32: [Int32]] = [:]
        for process in input.processes where process.ppid != process.pid { children[process.ppid, default: []].append(process.pid) }

        // A root is an agent process whose nearest agent ancestor is another agent, or none.
        let roots = agentOf.keys.filter { pid in
            guard let agent = agentOf[pid] else { return false }
            return nearestAgentAncestor(of: pid, table: table, agentOf: agentOf).map { agentOf[$0] != agent } ?? true
        }
        let rootSet = Set(roots)
        let me = source.currentUserID
        let protected = Self.ancestors(of: source.ownPID, table: table).union([source.ownPID])

        func isMCP(_ process: RawProcess) -> Bool {
            if ProcessClassifier.mentionsMCP(process.name) { return true }
            guard ProcessClassifier.isInterpreter(process.name) else { return false }
            return ProcessClassifier.looksLikeMCPServer(process, arguments: arguments.of(process.pid))
        }

        var members: [ProcessKey: AgentKind] = [:]
        var sessionInput: [(process: RawProcess, agent: AgentKind)] = []
        for pid in roots {
            guard let agent = agentOf[pid] else { continue }
            for member in subtreePIDs(pid, children: children, stopAt: rootSet) {
                guard let process = table[member] else { continue }
                members[process.key] = agent
                if agentOf[member] == agent { sessionInput.append((process, agent)) }
            }
        }
        let sessionMap = sessions?.sessions(for: sessionInput, source: source) ?? [:]

        func refusal(_ process: RawProcess) -> String? {
            if ProcessClassifier.isSystem(process) { return "\(process.name) is part of macOS; Domovy never signals it." }
            if process.uid != me { return "\(process.name) belongs to another user; Domovy only acts on your own processes." }
            if process.pid == source.ownPID { return "This is Domovy itself." }
            if protected.contains(process.pid) { return "Domovy runs inside this process tree, so it leaves \(process.name) alone." }
            return nil
        }

        func node(_ pid: Int32, agent: AgentKind?, rootAgent: AgentKind?, isRoot: Bool, orphan: Bool) -> ProcessNode? {
            guard let process = table[pid] else { return nil }
            let kind: ProcessKind
            if isRoot && !orphan { kind = .agent }
            else if let rootAgent, agentOf[pid] == rootAgent { kind = .helper }
            else if isMCP(process) { kind = .mcpServer }
            else { kind = .child }
            let cpu: Double? = {
                guard input.elapsed > 0, let now = process.cpuNanos, let before = input.previousCPU[process.key], now >= before else { return nil }
                return Double(now - before) / (input.elapsed * 1_000_000_000) * 100
            }()
            let growth = input.history.growth(of: process.key)
            let kids = (children[pid] ?? [])
                .filter { !rootSet.contains($0) }
                .compactMap { node($0, agent: agent, rootAgent: rootAgent, isRoot: false, orphan: false) }
                .sorted { $0.totalBytes > $1.totalBytes }
            return ProcessNode(
                key: process.key, ppid: process.ppid,
                name: kind == .agent ? (agent?.displayName ?? process.name) : ProcessClassifier.displayName(process, kind: kind, arguments: kind == .mcpServer ? arguments.of(pid) : nil),
                kind: kind, agent: agent, footprintBytes: process.footprintBytes, cpuPercent: cpu, startDate: process.startDate,
                isFrozen: process.isStopped, isOrphan: orphan, isGrowing: input.history.isGrowing(process.key),
                growthBytes: growth?.bytes, growthInterval: growth?.interval,
                sessionIDs: sessionMap[pid] ?? [], refusal: refusal(process), children: kids
            )
        }

        let groups = roots.compactMap { pid -> ProcessGroup? in
            guard let agent = agentOf[pid], let root = node(pid, agent: agent, rootAgent: agent, isRoot: true, orphan: false) else { return nil }
            return ProcessGroup(root: root, herdr: input.herdr?.placement(of: pid, table: table))
        }.sorted { $0.root.totalBytes > $1.root.totalBytes }

        // Orphans: your processes reparented to launchd that an agent started, by memory of an
        // earlier sample, by where their executable lives, or because they look like MCP servers.
        // Anything Herdr runs (its server, and every pane below it) still has a home: never an orphan.
        func runsUnderHerdr(_ process: RawProcess) -> Bool {
            HerdrProcessMap.isHerdr(process) || Self.ancestors(of: process.pid, table: table).contains { table[$0].map(HerdrProcessMap.isHerdr) == true }
        }
        let inTrees = Set(members.keys.map(\.pid))
        let orphans = input.processes.compactMap { process -> ProcessNode? in
            guard process.ppid == 1, process.uid == me, agentOf[process.pid] == nil, !inTrees.contains(process.pid),
                  !ProcessClassifier.isSystem(process), !protected.contains(process.pid), !runsUnderHerdr(process) else { return nil }
            let hint = input.remembered[process.key] ?? ProcessClassifier.agentHint(path: process.executablePath)
            guard hint != nil || isMCP(process) else { return nil }
            return node(process.pid, agent: hint, rootAgent: nil, isRoot: true, orphan: true)
        }.sorted { $0.totalBytes > $1.totalBytes }

        return Output(report: ProcessReport(groups: groups, orphans: orphans, takenAt: input.now), members: members)
    }

    private func nearestAgentAncestor(of pid: Int32, table: [Int32: RawProcess], agentOf: [Int32: AgentKind]) -> Int32? {
        var current = table[pid]?.ppid
        var steps = 0
        while let parent = current, parent > 1, steps < 128 {
            if agentOf[parent] != nil { return parent }
            current = table[parent]?.ppid
            steps += 1
        }
        return nil
    }

    private func subtreePIDs(_ pid: Int32, children: [Int32: [Int32]], stopAt roots: Set<Int32>) -> [Int32] {
        var result = [pid]
        var queue = [pid]
        while let next = queue.popLast(), result.count < 10_000 {
            for child in children[next] ?? [] where !roots.contains(child) {
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }

    static func ancestors(of pid: Int32, table: [Int32: RawProcess]) -> Set<Int32> {
        var result = Set<Int32>()
        var current = table[pid]?.ppid
        while let parent = current, parent > 1, result.insert(parent).inserted {
            current = table[parent]?.ppid
        }
        return result
    }
}
