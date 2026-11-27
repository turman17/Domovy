import Foundation

/// One process in an agent's tree or among the orphans, ready to show.
public struct ProcessNode: Identifiable, Hashable, Codable, Sendable {
    public var id: ProcessKey { key }
    public let key: ProcessKey
    public var pid: Int32 { key.pid }
    public let ppid: Int32
    /// Safe to show: the process name, plus the package name for a likely MCP server.
    public let name: String
    public let kind: ProcessKind
    /// The agent it belongs to; `nil` for an orphan nothing can be traced to.
    public let agent: AgentKind?
    public let footprintBytes: Int64?
    /// Share of one core since the previous sample; `nil` on the first sample.
    public let cpuPercent: Double?
    public let startDate: Date
    public let isFrozen: Bool
    /// Started by an agent that is gone: reparented to launchd.
    public let isOrphan: Bool
    /// Memory grew faster than the growth policy allows; see `growthBytes`.
    public let isGrowing: Bool
    /// Growth seen over `growthInterval` seconds, when there is enough history.
    public let growthBytes: Int64?
    public let growthInterval: TimeInterval?
    /// Sessions this process serves: Claude Code `sessions/<pid>.json` and roster workers,
    /// Codex threads whose writer lock it holds. Ids, lowercased.
    public let sessionIDs: [String]
    /// Why Domovy will not signal it (system process, another user's, Domovy itself), or `nil`.
    public let refusal: String?
    public let children: [ProcessNode]

    /// For `OutlineGroup`: `nil` when there is nothing to disclose.
    public var outlineChildren: [ProcessNode]? { children.isEmpty ? nil : children }

    /// This process and everything below it, parents first.
    public var subtree: [ProcessNode] { [self] + children.flatMap(\.subtree) }

    /// Memory of the whole subtree.
    public var totalBytes: Int64 { subtree.reduce(0) { $0 + ($1.footprintBytes ?? 0) } }
    public var totalCPUPercent: Double? {
        let values = subtree.compactMap(\.cpuPercent)
        return values.isEmpty ? nil : values.reduce(0, +)
    }
    public var anyFrozen: Bool { subtree.contains(where: \.isFrozen) }
    public var allFrozen: Bool { subtree.allSatisfy(\.isFrozen) }
}

/// One agent process tree: the agent's topmost process and everything it started.
public struct ProcessGroup: Identifiable, Hashable, Codable, Sendable {
    public var id: ProcessKey { root.key }
    public let root: ProcessNode
    /// The Herdr workspace and pane the agent runs in, when it runs in one.
    public let herdr: HerdrPlacement?
    public var agent: AgentKind { root.agent ?? .claudeCode }

    public init(root: ProcessNode, herdr: HerdrPlacement? = nil) {
        self.root = root
        self.herdr = herdr
    }
    /// Sessions of every process in the tree.
    public var sessionIDs: [String] {
        var seen: [String] = []
        for id in root.subtree.flatMap(\.sessionIDs) where !seen.contains(id) { seen.append(id) }
        return seen
    }
}

/// A full picture: agent trees, orphans, and totals.
public struct ProcessReport: Codable, Sendable {
    public let groups: [ProcessGroup]
    /// Agent-spawned processes whose agent is gone. Each with its own children.
    public let orphans: [ProcessNode]
    public let takenAt: Date

    public init(groups: [ProcessGroup], orphans: [ProcessNode], takenAt: Date) {
        self.groups = groups
        self.orphans = orphans
        self.takenAt = takenAt
    }

    public static let empty = ProcessReport(groups: [], orphans: [], takenAt: .distantPast)

    public var allNodes: [ProcessNode] { groups.flatMap(\.root.subtree) + orphans.flatMap(\.subtree) }
    public var processCount: Int { allNodes.count }
    public var totalBytes: Int64 { allNodes.reduce(0) { $0 + ($1.footprintBytes ?? 0) } }
    public var orphanCount: Int { orphans.count }
    public var orphanBytes: Int64 { orphans.reduce(0) { $0 + $1.totalBytes } }
    public var growing: [ProcessNode] { allNodes.filter(\.isGrowing) }

    public func node(pid: Int32) -> ProcessNode? {
        allNodes.first { $0.pid == pid }
    }

    /// The group or orphan tree that contains `pid`.
    func tree(containing pid: Int32) -> (root: ProcessNode, isOrphanTree: Bool)? {
        if let group = groups.first(where: { $0.root.subtree.contains { $0.pid == pid } }) { return (group.root, false) }
        if let orphan = orphans.first(where: { $0.subtree.contains { $0.pid == pid } }) { return (orphan, true) }
        return nil
    }
}
