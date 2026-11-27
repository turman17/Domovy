/// The agents Domovy knows about. One adapter per case.
public enum AgentKind: String, Codable, Sendable, CaseIterable, Hashable {
    case claudeCode
    case claudeDesktop
    case codex
    case cursor
    case gemini
    case antigravity
    case openCode
    case copilot
    /// Zed's Agent Panel (native threads).
    case zed
    /// VS Code's own chat (GitHub Copilot Chat and other chat participants).
    case vsCodeChat
    /// The Gemini Code Assist extension for VS Code.
    case geminiCodeAssist
    /// Qwen Code CLI (a Gemini CLI fork with Claude-Code-like storage).
    case qwen
    /// Moonshot's Kimi CLI.
    case kimi
    /// The Roo Code extension for VS Code and its forks.
    case rooCode
    /// Charm's Crush (one database per project).
    case crush
    /// Cline: the VS Code extension and the CLI share `~/.cline`.
    case cline
    /// Kilo Code, an OpenCode fork (`kilo`).
    case kilo
    /// Continue (`continue` is a Swift keyword).
    case continueDev
    /// Augment's CLI, Auggie (`~/.augment`).
    case auggie
    /// Factory's Droid CLI (`~/.factory`).
    case factoryDroid
    /// Aider: one chat history file per repository, no central index.
    case aider
    /// Kiro CLI and the Kiro IDE (`~/.kiro`). Read-only.
    case kiro
    /// Block's Goose (`sessions.db`). Read-only.
    case goose
    /// The community Grok CLI (`superagent-ai/grok-cli`, `~/.grok/grok.db`).
    case grok
    /// Amazon Q Developer CLI (one conversation per folder in its app database). Read-only.
    case amazonQ
    /// Measured on the Disk screen only; their sessions are encrypted, synced or unknown.
    case windsurf
    case trae
    case warp
    case amp
    case junie
    case iflow
    /// Herdr, the terminal workspace manager agents run in: measured on the Disk screen only.
    case herdr
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
        case .copilot: "Copilot CLI"
        case .zed: "Zed"
        case .vsCodeChat: "VS Code Chat"
        case .geminiCodeAssist: "Gemini Code Assist"
        case .qwen: "Qwen Code"
        case .kimi: "Kimi CLI"
        case .rooCode: "Roo Code"
        case .crush: "Crush"
        case .cline: "Cline"
        case .kilo: "Kilo Code"
        case .continueDev: "Continue"
        case .auggie: "Auggie"
        case .factoryDroid: "Factory Droid"
        case .aider: "Aider"
        case .kiro: "Kiro"
        case .goose: "Goose"
        case .grok: "Grok CLI"
        case .amazonQ: "Amazon Q CLI"
        case .windsurf: "Windsurf"
        case .trae: "Trae"
        case .warp: "Warp"
        case .amp: "Amp"
        case .junie: "Junie"
        case .iflow: "iFlow CLI"
        case .herdr: "Herdr"
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .huggingFace: "Hugging Face"
        }
    }

    /// A local model store rather than a coding agent.
    public var isModelStore: Bool {
        self == .ollama || self == .lmStudio || self == .huggingFace
    }

    /// An agent Domovy only measures (Disk screen): its sessions are encrypted, kept in a live
    /// synced database, on a server, or stored in a layout nobody has documented.
    public var isFootprintOnly: Bool {
        switch self {
        case .windsurf, .trae, .warp, .amp, .junie, .iflow, .herdr: true
        default: false
        }
    }

    /// Built from the agent's docs or source code and not yet checked against a real install
    /// (docs/research/agent_storage_formats.md). Shown as "Experimental" in the app, CLI and MCP.
    public var isExperimental: Bool {
        switch self {
        case .claudeCode, .claudeDesktop, .codex, .cursor, .gemini, .antigravity, .openCode,
             .zed, .vsCodeChat, .geminiCodeAssist, .herdr, .ollama, .huggingFace:
            false
        default:
            true
        }
    }

    /// One line explaining the "Experimental" mark.
    public static let experimentalNote = "Experimental: built from the agent's docs and source code, not yet verified on a real install."

    /// Has sessions of its own. Claude Desktop's are Claude Code sessions, listed under it.
    public var hasSessions: Bool {
        !isModelStore && self != .claudeDesktop && !isFootprintOnly
    }
}
