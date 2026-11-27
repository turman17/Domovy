import Foundation

/// What a cleanup rule does to the sessions it matches. Never a permanent delete.
public enum RuleAction: String, Codable, Hashable, Sendable, CaseIterable {
    /// Compress in place, or the agent's own archive (`codex archive`). The agent can still resume.
    case archive
    case moveToTrash
    case moveToQuarantine

    /// Where removed files go; `nil` for an archive.
    public var destination: Destination? {
        switch self {
        case .archive: nil
        case .moveToTrash: .trash
        case .moveToQuarantine: .quarantine
        }
    }

    public var displayName: String {
        switch self {
        case .archive: "Archive"
        case .moveToTrash: "Move to the Trash"
        case .moveToQuarantine: "Move to quarantine"
        }
    }
}

/// Which sessions a rule looks at. Empty lists mean "any".
public struct RuleScope: Codable, Hashable, Sendable {
    /// Only these agents; empty for every agent.
    public var agents: [AgentKind]
    /// Only sessions whose project path contains one of these texts (case-insensitive).
    public var projects: [String]
    /// Only sessions in one of these states. Live sessions never match, whatever this says.
    public var statuses: [Session.Status]

    public init(agents: [AgentKind] = [], projects: [String] = [], statuses: [Session.Status] = []) {
        self.agents = agents
        self.projects = projects
        self.statuses = statuses
    }

    public func contains(_ session: Session) -> Bool {
        if !agents.isEmpty, !agents.contains(session.agent) { return false }
        if !projects.isEmpty {
            let path = (session.projectPath ?? "").lowercased()
            let wanted = projects.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
            if !wanted.isEmpty, !wanted.contains(where: { path.contains($0) }) { return false }
        }
        if !statuses.isEmpty {
            let matches = statuses.contains { $0 == session.status || ($0 == .archived && session.isArchived) }
            if !matches { return false }
        }
        return true
    }
}

/// When a rule acts. Every condition that is set must hold.
public struct RuleCondition: Codable, Hashable, Sendable {
    /// Last active more than this many days ago.
    public var idleDays: Int?
    /// At least this big.
    public var minimumBytes: Int64?
    /// Archived more than this many days ago (by Domovy's undo log; otherwise counted from
    /// the last activity, which the archive keeps).
    public var archivedDays: Int?
    /// The agent's own retention sweep deletes it within this many days.
    public var expiresWithinDays: Int?

    public init(idleDays: Int? = nil, minimumBytes: Int64? = nil, archivedDays: Int? = nil, expiresWithinDays: Int? = nil) {
        self.idleDays = idleDays
        self.minimumBytes = minimumBytes
        self.archivedDays = archivedDays
        self.expiresWithinDays = expiresWithinDays
    }

    public var isEmpty: Bool { idleDays == nil && minimumBytes == nil && archivedDays == nil && expiresWithinDays == nil }
}

/// A cleanup rule that runs on its own: "Archive Codex sessions idle for 30 days".
public struct CleanupRule: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// The preset it came from, if any ("archive-idle-30").
    public var presetID: String?
    /// A name the user gave it, or the preset's; the sentence is shown otherwise.
    public var name: String?
    public var isEnabled: Bool
    /// Scheduled runs only notify and offer a review instead of executing.
    public var askBeforeRunning: Bool
    public var action: RuleAction
    public var scope: RuleScope
    public var condition: RuleCondition
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        presetID: String? = nil,
        name: String? = nil,
        isEnabled: Bool = false,
        askBeforeRunning: Bool = false,
        action: RuleAction,
        scope: RuleScope = RuleScope(),
        condition: RuleCondition,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.presetID = presetID
        self.name = name
        self.isEnabled = isEnabled
        self.askBeforeRunning = askBeforeRunning
        self.action = action
        self.scope = scope
        self.condition = condition
        self.createdAt = createdAt
    }

    /// The name if there is one, else the sentence.
    public var title: String {
        if let name, !name.isEmpty { return name }
        return sentence
    }

    /// Why the rule cannot be saved, or `nil`.
    public var validationProblem: String? {
        if condition.isEmpty { return "Choose at least one condition, such as idle for 30 days." }
        let numbers = [condition.idleDays, condition.archivedDays, condition.expiresWithinDays].compactMap { $0 }
        if numbers.contains(where: { $0 < 0 || $0 > 3_650 }) { return "Days must be between 0 and 3650." }
        if let bytes = condition.minimumBytes, bytes < 0 { return "The size must not be negative." }
        if action == .archive, condition.archivedDays != nil || scope.statuses == [.archived] {
            return "Archived sessions are already archived. Choose Move to the Trash for them."
        }
        return nil
    }

    /// Whether `session` is one this rule acts on now. Live sessions never match; an archive
    /// rule skips sessions that are already archived.
    /// - Parameter archivedAt: when Domovy archived the session, if it did.
    public func matches(_ session: Session, archivedAt: Date?, now: Date) -> Bool {
        guard !condition.isEmpty, session.status != .live, scope.contains(session) else { return false }
        if action == .archive, session.isArchived || session.status == .archived { return false }
        let day: TimeInterval = 86_400
        if let days = condition.idleDays, now.timeIntervalSince(session.lastActive) < TimeInterval(days) * day { return false }
        if let bytes = condition.minimumBytes, session.sizeBytes < bytes { return false }
        if let days = condition.archivedDays {
            guard session.isArchived || session.status == .archived else { return false }
            if now.timeIntervalSince(archivedAt ?? session.lastActive) < TimeInterval(days) * day { return false }
        }
        if let days = condition.expiresWithinDays {
            let soon = session.status == .expiring
                || session.expiresAt.map { $0.timeIntervalSince(now) <= TimeInterval(days) * day } == true
            if !soon { return false }
        }
        return true
    }

    // MARK: Sentence

    /// The rule in plain words: "Move Codex sessions idle for 90 days to the Trash".
    public var sentence: String {
        var subject = "sessions"
        if !scope.agents.isEmpty {
            let names = scope.agents.map(\.displayName)
            subject = names.count > 3 ? "sessions of \(names.count) agents" : Self.list(names, joiner: "and") + " sessions"
        }
        if !scope.statuses.isEmpty {
            subject = Self.list(scope.statuses.map(\.rawValue), joiner: "or") + " " + subject
        }
        var parts = [subject]
        let projects = scope.projects.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !projects.isEmpty { parts.append("in " + Self.list(projects.map { "\u{201C}\($0)\u{201D}" }, joiner: "or")) }
        var conditions: [String] = []
        if let days = condition.idleDays { conditions.append("idle for \(Self.days(days))") }
        if let days = condition.archivedDays { conditions.append("archived for \(Self.days(days))") }
        if let bytes = condition.minimumBytes {
            conditions.append("larger than \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
        }
        if let days = condition.expiresWithinDays {
            let owner = scope.agents.count == 1 ? scope.agents[0].displayName : "their agent"
            conditions.append(days == 0 ? "about to be deleted by \(owner)" : "due to be deleted by \(owner) within \(Self.days(days))")
        }
        if !conditions.isEmpty { parts.append(conditions.joined(separator: " and ")) }
        let body = parts.joined(separator: " ")
        switch action {
        case .archive: return "Archive \(body)"
        case .moveToTrash: return "Move \(body) to the Trash"
        case .moveToQuarantine: return "Move \(body) to the quarantine folder"
        }
    }

    /// What the action does, for the editor and the review sheet.
    public var actionExplanation: String {
        switch action {
        case .archive: "Compresses the session files in place; the agent can still resume them. Dates are kept. You can undo this."
        case .moveToTrash: "Moves the session files to the Trash and removes them from the agent's lists. You can undo this."
        case .moveToQuarantine: "Moves the session files to Domovy's quarantine folder and removes them from the agent's lists. You can undo this."
        }
    }

    static func days(_ n: Int) -> String { "\(n) \(n == 1 ? "day" : "days")" }

    static func list(_ items: [String], joiner: String) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) \(joiner) \(items[1])"
        default: items.dropLast().joined(separator: ", ") + ", \(joiner) " + items[items.count - 1]
        }
    }
}

// MARK: Presets

extension CleanupRule {
    /// The rules Domovy offers. All of them start turned off.
    public static var presets: [CleanupRule] {
        let epoch = Date(timeIntervalSince1970: 0)
        return [
            CleanupRule(
                id: UUID(uuidString: "D0C00001-6D6F-4000-8000-000000000001") ?? UUID(),
                presetID: "archive-before-claude-sweep",
                name: "Archive Claude Code sessions before Claude Code deletes them",
                action: .archive,
                scope: RuleScope(agents: [.claudeCode]),
                condition: RuleCondition(expiresWithinDays: 7),
                createdAt: epoch
            ),
            CleanupRule(
                id: UUID(uuidString: "D0C00002-6D6F-4000-8000-000000000002") ?? UUID(),
                presetID: "archive-idle-30",
                name: "Archive sessions idle for 30 days",
                action: .archive,
                condition: RuleCondition(idleDays: 30),
                createdAt: epoch
            ),
            CleanupRule(
                id: UUID(uuidString: "D0C00003-6D6F-4000-8000-000000000003") ?? UUID(),
                presetID: "trash-idle-90",
                name: "Move sessions idle for 90 days to the Trash",
                action: .moveToTrash,
                condition: RuleCondition(idleDays: 90),
                createdAt: epoch
            ),
        ]
    }

    public static func preset(_ id: String) -> CleanupRule? {
        presets.first { $0.presetID == id }
    }
}

// MARK: Agent ids

/// Stable lowercase agent ids for the CLI and rule files ("claude-code", "codex"), the same
/// ones the MCP tools take.
public enum RuleAgentID {
    public static var all: [String] { SessionAgent.allCases.map(SessionAgent.id(of:)) }
    public static func id(of kind: AgentKind) -> String { SessionAgent.id(of: kind) }
    public static func parse(_ text: String) -> AgentKind? { SessionAgent.parse(text) }
}

/// Sizes as people type them: "50 MB", "1.5GB", "200k", or bytes.
public enum RuleSize {
    public static func parse(_ text: String) -> Int64? { DomovyTools.parseSize(.string(text)) }
}
