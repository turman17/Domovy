/// The agents Domovy knows about. One adapter per case.
public enum AgentKind: String, Codable, Sendable, CaseIterable, Hashable {
    case claudeCode
    case claudeDesktop
    case codex
    case cursor
    case gemini
    case openCode

    /// Human readable name as shown in the UI and CLI.
    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude Desktop"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .gemini: "Gemini"
        case .openCode: "OpenCode"
        }
    }
}
