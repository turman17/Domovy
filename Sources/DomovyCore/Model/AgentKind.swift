/// The agents Domovy knows about. One adapter per case.
public enum AgentKind: String, Codable, Sendable, CaseIterable, Hashable {
    case claudeCode
    case claudeDesktop
    case codex
    case cursor
    case gemini
    case antigravity
    case openCode
    /// Local model stores: measured and cleaned on the Disk screen, no sessions.
    case ollama
    case lmStudio
    case huggingFace

    /// Human readable name as shown in the UI and CLI.
    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude Desktop"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .gemini: "Gemini CLI"
        case .antigravity: "Antigravity"
        case .openCode: "OpenCode"
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .huggingFace: "Hugging Face"
        }
    }

    /// A local model store rather than a coding agent.
    public var isModelStore: Bool {
        self == .ollama || self == .lmStudio || self == .huggingFace
    }
}
