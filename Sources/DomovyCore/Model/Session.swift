import Foundation

/// One agent session as the user thinks of it: a conversation with a transcript on disk.
public struct Session: Identifiable, Hashable, Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Not running; safe to act on.
        case idle
        /// An agent process currently references this session. Never touch it.
        case live
        /// Compressed by Domovy (APFS transparent compression); the agent can still resume it.
        case archived
        /// The agent's own retention sweep will delete it soon.
        case expiring
    }

    /// The agent's own identifier (Claude Code: the transcript UUID).
    public let id: String
    public let agent: AgentKind
    /// First user prompt or custom title. `nil` when nothing readable was found.
    public let title: String?
    /// Working directory of the session as recorded by the agent, if known.
    public let projectPath: String?
    /// Modification time of the primary transcript.
    public let lastActive: Date
    /// Logical size of every artifact that belongs to the session.
    public let sizeBytes: Int64
    public let status: Status
    /// When the agent's retention sweep will consider this session stale, if the agent has one.
    public let expiresAt: Date?
    /// The primary transcript file. Adapters use it to locate companions.
    public let transcriptURL: URL
    /// The transcript is compressed. True also when `status` reports something more urgent
    /// (live, expiring): compression keeps mtimes, so the agent's sweep still applies.
    public let isArchived: Bool
    /// Claude Desktop also lists this session (a Claude Code session started from Desktop).
    public let desktop: DesktopLink?

    public init(
        id: String,
        agent: AgentKind,
        title: String?,
        projectPath: String?,
        lastActive: Date,
        sizeBytes: Int64,
        status: Status,
        expiresAt: Date?,
        transcriptURL: URL,
        isArchived: Bool = false,
        desktop: DesktopLink? = nil
    ) {
        self.id = id
        self.agent = agent
        self.title = title
        self.projectPath = projectPath
        self.lastActive = lastActive
        self.sizeBytes = sizeBytes
        self.status = status
        self.expiresAt = expiresAt
        self.transcriptURL = transcriptURL
        self.isArchived = isArchived
        self.desktop = desktop
    }

    /// "Claude Code · Desktop" when Claude Desktop lists the session too.
    public var agentLabel: String {
        desktop == nil ? agent.displayName : "\(agent.displayName) \u{00B7} Desktop"
    }

    /// Last path component of the project, for compact display.
    public var projectName: String? {
        projectPath.map { URL(fileURLWithPath: $0).lastPathComponent }
    }
}
