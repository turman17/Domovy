import Foundation

/// What a running Herdr server reports about its workspaces, panes and agents, from
/// `herdr workspace list`, `herdr pane list` and `herdr agent list` (verified, 0.9.5). Only ids,
/// labels, folders, agent kinds and statuses are decoded; terminal titles and screen content
/// never are.
public struct HerdrState: Hashable, Sendable {
    public var workspaces: [HerdrWorkspace]
    public var panes: [HerdrPane]
    public var agents: [HerdrAgent]

    public init(workspaces: [HerdrWorkspace] = [], panes: [HerdrPane] = [], agents: [HerdrAgent] = []) {
        self.workspaces = workspaces
        self.panes = panes
        self.agents = agents
    }

    public static let empty = HerdrState()

    public func workspace(_ id: String) -> HerdrWorkspace? { workspaces.first { $0.id == id } }

    /// Where a pane sits, with readable names.
    public func placement(ofPane id: String) -> HerdrPlacement? {
        guard let pane = panes.first(where: { $0.id == id }) ?? agents.first(where: { $0.paneID == id }).map(\.pane) else { return nil }
        let agent = agents.first { $0.paneID == id }
        return HerdrPlacement(workspaceID: pane.workspaceID, workspaceLabel: workspace(pane.workspaceID)?.label ?? pane.workspaceID,
                              tabID: pane.tabID, paneID: pane.id, agentName: agent?.name, agentKind: agent?.kind, agentStatus: agent?.status)
    }

    /// The pane running `session`: the agent Herdr reports with this session id, else the only
    /// agent of the same kind working in the session's project folder. Never a guess between two.
    public func placement(of session: Session) -> HerdrPlacement? {
        guard let kind = HerdrAgentKind.kind(for: session.agent) else { return nil }
        let sameKind = agents.filter { $0.kind == kind }
        let id = session.id.lowercased()
        if let exact = sameKind.first(where: { $0.sessionID?.lowercased() == id }) { return placement(ofPane: exact.paneID) }
        guard session.status == .live, let project = session.projectPath.map(Self.normalized) else { return nil }
        // An agent that reports another session is not this one.
        let candidates = sameKind.filter { $0.sessionID == nil && $0.cwd.map(Self.normalized) == project }
        guard candidates.count == 1, let only = candidates.first else { return nil }
        return placement(ofPane: only.paneID)
    }

    /// The workspace a new tab for `folder` belongs in: one with a pane already in that folder.
    public func workspace(forFolder folder: String) -> HerdrWorkspace? {
        let target = Self.normalized(folder)
        let ids = panes.filter { $0.cwd.map(Self.normalized) == target }.map(\.workspaceID)
        return workspaces.first { ids.contains($0.id) }
    }

    static func normalized(_ path: String) -> String {
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        return standard.count > 1 && standard.hasSuffix("/") ? String(standard.dropLast()) : standard
    }
}

public struct HerdrWorkspace: Hashable, Sendable, Decodable {
    /// `w1`: opaque, stable for the server's life.
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }

    enum CodingKeys: String, CodingKey {
        case id = "workspace_id"
        case label
    }
}

public struct HerdrPane: Hashable, Sendable, Decodable {
    /// `w1:p1`.
    public let id: String
    public let workspaceID: String
    public let tabID: String
    public let cwd: String?

    public init(id: String, workspaceID: String, tabID: String, cwd: String?) {
        self.id = id
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.cwd = cwd
    }

    enum CodingKeys: String, CodingKey {
        case id = "pane_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case cwd
    }
}

public struct HerdrAgent: Hashable, Sendable, Decodable {
    public let paneID: String
    public let workspaceID: String
    public let tabID: String
    /// Herdr's agent kind: `claude`, `codex`, `agy`, ...
    public let kind: String?
    /// The live agent name (`[a-z][a-z0-9_-]{0,31}`), when it has one.
    public let name: String?
    /// `idle`, `working`, `blocked`, `done` or `unknown`.
    public let status: String
    public let cwd: String?
    /// The agent's own session id, when Herdr's integration hook reported it.
    public let sessionID: String?

    public init(paneID: String, workspaceID: String, tabID: String, kind: String?, name: String?, status: String, cwd: String?, sessionID: String?) {
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.kind = kind
        self.name = name
        self.status = status
        self.cwd = cwd
        self.sessionID = sessionID
    }

    var pane: HerdrPane { HerdrPane(id: paneID, workspaceID: workspaceID, tabID: tabID, cwd: cwd) }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case kind = "agent"
        case name
        case status = "agent_status"
        case cwd
        case session = "agent_session"
    }

    /// `agent_session` is `{"kind": "id" | "path", "value": ...}`; only an id is kept.
    private struct SessionRef: Decodable {
        let kind: String
        let value: String
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paneID = try container.decode(String.self, forKey: .paneID)
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        tabID = try container.decode(String.self, forKey: .tabID)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        let session = try? container.decodeIfPresent(SessionRef.self, forKey: .session)
        sessionID = session.flatMap { $0.kind == "id" ? $0.value : nil }
    }
}

/// Where something runs in Herdr, in words a person recognises.
public struct HerdrPlacement: Hashable, Codable, Sendable {
    public let workspaceID: String
    /// The workspace's label as the sidebar shows it (`domovy`), or its id.
    public let workspaceLabel: String
    public let tabID: String
    public let paneID: String
    public let agentName: String?
    public let agentKind: String?
    public let agentStatus: String?

    public init(workspaceID: String, workspaceLabel: String, tabID: String, paneID: String,
                agentName: String? = nil, agentKind: String? = nil, agentStatus: String? = nil) {
        self.workspaceID = workspaceID
        self.workspaceLabel = workspaceLabel
        self.tabID = tabID
        self.paneID = paneID
        self.agentName = agentName
        self.agentKind = agentKind
        self.agentStatus = agentStatus
    }

    /// "domovy, pane wD:p2".
    public var title: String { "\(workspaceLabel), pane \(paneID)" }

    /// "Live in Herdr: domovy, pane wD:p2."
    public var liveReason: String { "Live in Herdr: \(title)." }
}

/// Herdr's names for the agents Domovy knows (`herdr agent` lists them).
public enum HerdrAgentKind {
    public static func kind(for agent: AgentKind) -> String? {
        switch agent {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .gemini: "gemini"
        case .cursor: "cursor"
        case .antigravity: "agy"
        case .cline: "cline"
        case .openCode: "opencode"
        case .copilot: "copilot"
        case .kimi: "kimi"
        case .kiro: "kiro"
        case .factoryDroid: "droid"
        case .amp: "amp"
        case .grok: "grok"
        case .kilo: "kilo"
        case .qwen: "qwen"
        default: nil
        }
    }

    public static func agent(for kind: String) -> AgentKind? {
        AgentKind.allCases.first { self.kind(for: $0) == kind }
    }
}

extension HerdrState {
    /// Parses the three list responses. Each is `{"result": {"workspaces"|"panes"|"agents": [...]}}`.
    /// A list that does not parse is left empty; a workspace list that does not parse means
    /// the output is not Herdr's, and the whole state is `nil`.
    public static func parse(workspaces: Data, panes: Data, agents: Data) -> HerdrState? {
        struct Envelope<Item: Decodable>: Decodable {
            struct Result: Decodable {
                let workspaces: [Item]?
                let panes: [Item]?
                let agents: [Item]?
            }
            let result: Result
        }
        let decoder = JSONDecoder()
        guard let spaces = try? decoder.decode(Envelope<HerdrWorkspace>.self, from: workspaces).result.workspaces else { return nil }
        return HerdrState(
            workspaces: spaces,
            panes: (try? decoder.decode(Envelope<HerdrPane>.self, from: panes).result.panes) ?? [],
            agents: (try? decoder.decode(Envelope<HerdrAgent>.self, from: agents).result.agents) ?? []
        )
    }

    /// `herdr pane process-info`: the pane's shell pid only. Foreground command lines in the
    /// same response are never decoded.
    public static func shellPID(fromProcessInfo data: Data) -> Int32? {
        struct Envelope: Decodable {
            struct Result: Decodable {
                struct Info: Decodable { let shell_pid: Int32? }
                let process_info: Info
            }
            let result: Result
        }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.result.process_info.shell_pid
    }

    /// The new pane of `workspace create` or `tab create`: `.result.root_pane.pane_id`.
    public static func rootPaneID(fromCreated data: Data) -> String? {
        struct Envelope: Decodable {
            struct Result: Decodable {
                struct Pane: Decodable { let pane_id: String }
                let root_pane: Pane
            }
            let result: Result
        }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.result.root_pane.pane_id
    }
}

extension HerdrState {
    /// A session whose agent runs in a Herdr pane is live, and its plan says where. The
    /// agents' own signals may miss it (a Codex thread without a writer lock yet); Herdr's
    /// report of the session id is enough to refuse.
    public func markingLive(_ plan: Plan, for session: Session) -> Plan {
        guard let placement = placement(of: session) else { return plan }
        var plan = plan
        let check = plan.liveCheck
        plan.liveCheck = LiveCheckResult(isLive: true, reasons: [placement.liveReason] + check.reasons.filter { $0 != placement.liveReason },
                                         checkedSignals: check.checkedSignals + ["Herdr agent list"], openHandles: check.openHandles)
        return plan
    }
}
