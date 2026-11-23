import Foundation

/// An agent's own retention sweep, in words the user can act on. Shown above the sessions
/// that are about to go ("Gemini CLI deletes chats older than 30 days.").
public struct RetentionRule: Hashable, Sendable {
    public let agent: AgentKind
    /// The rule itself: "Claude Code deletes sessions older than 30 days."
    public let rule: String
    /// What archiving does here and how to keep sessions longer.
    public let advice: String
    /// The settings file that controls the rule, if there is one.
    public let settingsFile: URL?
    /// Domovy can archive this agent's expiring sessions ("Archive all").
    public let canArchive: Bool

    public init(agent: AgentKind, rule: String, advice: String, settingsFile: URL?, canArchive: Bool) {
        self.agent = agent
        self.rule = rule
        self.advice = advice
        self.settingsFile = settingsFile
        self.canArchive = canArchive
    }
}

/// Adapters whose agent deletes sessions on its own.
public protocol RetentionReporting: Sendable {
    /// The rule as configured now, or `nil` when the sweep is turned off.
    func retentionRule() -> RetentionRule?
}

extension ClaudeCodeAdapter: RetentionReporting {
    public func retentionRule() -> RetentionRule? {
        let days = cleanupPeriodDays()
        return RetentionRule(
            agent: kind,
            rule: "Claude Code deletes sessions older than \(days) days.",
            advice: "Archiving compresses them to free space but keeps their dates, so the sweep still applies. To keep them longer, raise cleanupPeriodDays in Claude Code settings.",
            settingsFile: root.appendingPathComponent("settings.json"),
            canArchive: true
        )
    }
}
