import Foundation

/// The agents `domo connect` can register Domovy's MCP server (and skill) with. Paths and
/// formats: docs/research/mcp_skill_install.md.
public enum ConnectAgent: String, CaseIterable, Codable, Sendable, Identifiable {
    case claudeCode = "claude-code"
    case codex
    case gemini
    case qwen
    case cursor
    case openCode = "opencode"
    case copilot
    case antigravity
    case claudeDesktop = "claude-desktop"
    case zed
    case vsCode = "vscode"
    case kimi
    case crush
    case cline
    case kilo
    case rooCode = "roo-code"
    case continueDev = "continue"
    case auggie
    case factoryDroid = "factory-droid"
    case kiro
    case amazonQ = "amazon-q"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .qwen: "Qwen Code"
        case .cursor: "Cursor"
        case .openCode: "OpenCode"
        case .copilot: "Copilot CLI"
        case .antigravity: "Antigravity"
        case .claudeDesktop: "Claude Desktop"
        case .zed: "Zed"
        case .vsCode: "VS Code"
        case .kimi: "Kimi CLI"
        case .crush: "Crush"
        case .cline: "Cline"
        case .kilo: "Kilo Code"
        case .rooCode: "Roo Code"
        case .continueDev: "Continue"
        case .auggie: "Auggie"
        case .factoryDroid: "Factory Droid"
        case .kiro: "Kiro"
        case .amazonQ: "Amazon Q CLI"
        }
    }

    /// Roo Code's folder in VS Code's global storage (RooCodeInc/Roo-Code@b867ec91, src/utils/storage.ts#L63-L67).
    static let rooSettings = "Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline"

    /// "claude-code", "Claude Code", "claudecode" all match.
    public static func parse(_ text: String) -> ConnectAgent? {
        let wanted = text.lowercased().filter { $0.isLetter || $0.isNumber }
        return allCases.first { agent in
            [agent.rawValue, agent.displayName].contains { $0.lowercased().filter { $0.isLetter || $0.isNumber } == wanted }
        }
    }

    /// Any of these (relative to home) means the agent is installed.
    var markers: [String] {
        switch self {
        case .claudeCode: [".claude", ".claude.json"]
        case .codex: [".codex"]
        case .gemini: [".gemini/settings.json", ".gemini/tmp"]
        case .qwen: [".qwen"]
        case .cursor: [".cursor"]
        case .openCode: [".config/opencode", ".local/share/opencode"]
        case .copilot: [".copilot"]
        case .antigravity: [".gemini/config", ".gemini/antigravity"]
        case .claudeDesktop: ["Library/Application Support/Claude"]
        case .zed: [".config/zed"]
        case .vsCode: ["Library/Application Support/Code/User"]
        case .kimi: [".kimi"]
        case .crush: [".config/crush", ".local/share/crush"]
        case .cline: [".cline"]
        case .kilo: [".config/kilo", ".local/share/kilo"]
        case .rooCode: [Self.rooSettings]
        case .continueDev: [".continue"]
        case .auggie: [".augment"]
        case .factoryDroid: [".factory"]
        case .kiro: [".kiro"]
        case .amazonQ: [".aws/amazonq", "Library/Application Support/amazon-q"]
        }
    }

    /// The config file that lists MCP servers.
    func configFile(home: URL) -> URL {
        let relative: String
        switch self {
        case .claudeCode: relative = ".claude.json"
        case .codex: relative = ".codex/config.toml"
        case .gemini: relative = ".gemini/settings.json"
        case .qwen: relative = ".qwen/settings.json"
        case .cursor: relative = ".cursor/mcp.json"
        case .openCode:
            let jsonc = home.appendingPathComponent(".config/opencode/opencode.jsonc")
            relative = FileManager.default.fileExists(atPath: jsonc.path) ? ".config/opencode/opencode.jsonc" : ".config/opencode/opencode.json"
        case .copilot: relative = ".copilot/mcp-config.json"
        case .antigravity: relative = ".gemini/config/mcp_config.json"
        case .claudeDesktop: relative = "Library/Application Support/Claude/claude_desktop_config.json"
        case .zed: relative = ".config/zed/settings.json"
        case .vsCode: relative = "Library/Application Support/Code/User/mcp.json"
        case .kimi: relative = ".kimi/mcp.json"
        case .crush: relative = ".config/crush/crush.json"
        case .cline: relative = ".cline/data/settings/cline_mcp_settings.json"
        case .kilo:
            // The first of these that exists, else kilo.json (Kilo-Org/kilocode@bfdec549, packages/opencode/src/cli/cmd/mcp.ts#L396-L426).
            let names = ["kilo.jsonc", "kilo.json", "opencode.jsonc", "opencode.json"]
            let found = names.first { FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/kilo/\($0)").path) }
            relative = ".config/kilo/" + (found ?? "kilo.json")
        case .rooCode: relative = Self.rooSettings + "/settings/mcp_settings.json"
        case .continueDev: relative = ".continue/mcpServers/domovy.json"
        // User settings, written by `auggie mcp add` without --project/--local (@augmentcode/auggie@1.2.2 bundle).
        case .auggie: relative = ".augment/settings.json"
        // https://docs.factory.ai/cli/configuration/mcp ("User: ~/.factory/mcp.json").
        case .factoryDroid: relative = ".factory/mcp.json"
        // https://kiro.dev/docs/cli/mcp/configuration/ (user level, shared by the CLI and the IDE).
        case .kiro: relative = ".kiro/settings/mcp.json"
        // aws/amazon-q-developer-cli@15cc8f3c crates/chat-cli/src/util/paths.rs#L61 (global MCP_CONFIG).
        case .amazonQ: relative = ".aws/amazonq/mcp.json"
        }
        return home.appendingPathComponent(relative)
    }

    /// Where the agent reads user skills (Agent Skills `<dir>/<name>/SKILL.md`); `nil` when it
    /// has none Domovy may write to. Most agents read the shared `~/.agents/skills`, so one copy
    /// there serves them all; the rest get a folder of their own. Never a shared rules file.
    /// Sources: docs/research/mcp_skill_install.md, "Skills per agent".
    func skillsDirectory(home: URL) -> URL? {
        let relative: String?
        switch self {
        case .claudeCode: relative = ".claude/skills"
        case .antigravity: relative = ".gemini/config/skills"
        case .cline: relative = ".cline/skills"
        case .continueDev: relative = ".continue/skills"
        case .kiro: relative = ".kiro/skills"
        // Kimi reads ~/.agents/skills only while ~/.config/agents/skills does not exist; its own folder always loads.
        case .kimi: relative = ".kimi/skills"
        // Claude Desktop chat skills are uploaded in claude.ai; Amazon Q CLI was replaced by Kiro CLI.
        case .claudeDesktop, .amazonQ: relative = nil
        case .codex, .gemini, .qwen, .cursor, .openCode, .copilot, .zed, .vsCode, .crush, .kilo, .rooCode, .auggie, .factoryDroid:
            relative = ".agents/skills"
        }
        return relative.map { home.appendingPathComponent($0, isDirectory: true) }
    }

    var isTOML: Bool { self == .codex }

    /// The JSON object that holds servers, by key path. OpenCode's newer layout nests them
    /// under `mcp.servers`; an existing file with that shape keeps it.
    func serverPath(in data: Data?) -> [String] {
        switch self {
        case .claudeCode, .gemini, .qwen, .cursor, .copilot, .antigravity, .claudeDesktop, .kimi, .cline, .rooCode, .continueDev,
             .auggie, .factoryDroid, .kiro, .amazonQ: ["mcpServers"]
        case .crush, .kilo: ["mcp"]
        case .zed: ["context_servers"]
        case .vsCode: ["servers"]
        case .codex: ["mcp_servers"]
        case .openCode:
            if let data, (try? JSONCEditor.value(of: "servers", at: ["mcp"], in: data))?.objectValue != nil { ["mcp", "servers"] } else { ["mcp"] }
        }
    }

    /// The server entry in this agent's shape.
    func entry(command: [String], path: [String], siblings: [String: JSONValue]) -> OrderedJSON {
        let executable = OrderedJSON.string(command[0])
        let args = OrderedJSON.array(command.dropFirst().map { .string($0) })
        switch self {
        case .claudeCode:
            return .object([("type", .string("stdio")), ("command", executable), ("args", args), ("env", .object([]))])
        case .cursor, .vsCode:
            return .object([("type", .string("stdio")), ("command", executable), ("args", args)])
        case .copilot:
            return .object([("type", .string("local")), ("command", executable), ("args", args), ("tools", .array([.string("*")]))])
        case .openCode:
            let all = OrderedJSON.array(command.map { .string($0) })
            return path.count > 1
                ? .object([("type", .string("local")), ("command", all)])
                : .object([("type", .string("local")), ("command", all), ("enabled", .bool(true))])
        case .zed:
            // Older Zed builds wrote "source": "custom"; match the user's other entries.
            let custom = siblings.values.contains { $0["source"]?.stringValue == "custom" }
            return .object((custom ? [("source", OrderedJSON.string("custom"))] : []) + [("command", executable), ("args", args), ("env", .object([]))])
        case .crush:
            return .object([("type", .string("stdio")), ("command", executable), ("args", args)])
        case .kilo:
            return .object([("type", .string("local")), ("command", .array(command.map { .string($0) })), ("enabled", .bool(true))])
        case .cline:
            return .object([("command", executable), ("args", args), ("disabled", .bool(false))])
        case .factoryDroid:
            return .object([("type", .string("stdio")), ("command", executable), ("args", args), ("disabled", .bool(false))])
        case .gemini, .qwen, .antigravity, .claudeDesktop, .codex, .kimi, .rooCode, .continueDev, .auggie, .kiro, .amazonQ:
            return .object([("command", executable), ("args", args)])
        }
    }

    /// The agent's own command for adding and removing a user-level server, if it has one.
    var cli: (name: String, add: [String], remove: [String])? {
        let name = MCPRegistration.serverName
        switch self {
        case .claudeCode: return ("claude", ["mcp", "add", "--transport", "stdio", "--scope", "user", name, "--"], ["mcp", "remove", name, "--scope", "user"])
        case .codex: return ("codex", ["mcp", "add", name, "--"], ["mcp", "remove", name])
        case .gemini: return ("gemini", ["mcp", "add", "-s", "user", name], ["mcp", "remove", "-s", "user", name])
        case .qwen: return ("qwen", ["mcp", "add", "-s", "user", name], ["mcp", "remove", name])
        case .copilot: return ("copilot", ["mcp", "add", name, "--"], ["mcp", "remove", name])
        // MoonshotAI/kimi-cli@9ab1286b src/kimi_cli/cli/mcp.py#L83-L191.
        case .kimi: return ("kimi", ["mcp", "add", "--transport", "stdio", name, "--"], ["mcp", "remove", name])
        // Auggie's `mcp add` takes the arguments as one string, Droid's the command as one string, and
        // Kiro's and Amazon Q's need flags per value; Domovy edits their JSON files instead.
        case .cursor, .openCode, .antigravity, .claudeDesktop, .zed, .vsCode, .crush, .cline, .kilo, .rooCode, .continueDev,
             .auggie, .factoryDroid, .kiro, .amazonQ: return nil
        }
    }

    /// An app that rewrites this config file while it runs, so Domovy edits it only while quit.
    var rewritesConfigWhileRunning: ProcessMatcher? {
        switch self {
        case .claudeDesktop: ClaudeDesktopRegistry.processMatcher
        case .claudeCode: ProcessMatcher(appName: "Claude Code", names: ["claude"], quitAdvice: "Quit every Claude Code session first; it rewrites ~/.claude.json while it runs.")
        default: nil
        }
    }

    /// What the user has to do for the change to take effect.
    public var reloadAdvice: String {
        switch self {
        case .claudeDesktop: "Restart Claude Desktop to load it."
        case .cursor, .zed, .vsCode, .antigravity, .rooCode, .continueDev: "\(displayName) picks it up on its next start (or reload its MCP list)."
        case .factoryDroid, .kiro: "\(displayName) reloads its MCP config when the file changes."
        default: "New \(displayName) sessions load it."
        }
    }
}

/// The server name and command Domovy registers.
public enum MCPRegistration {
    public static let serverName = "domovy"

    /// The `domo` executable to register: `override`, else the running one. A Homebrew Cellar
    /// path becomes the stable `<prefix>/bin/domo` link, so upgrades keep working.
    public static func domoExecutable(override: String? = nil, running: URL? = Bundle.main.executableURL) -> URL? {
        if let override, !override.isEmpty { return URL(fileURLWithPath: override).standardizedFileURL }
        guard let running else { return nil }
        let path = running.standardizedFileURL.path
        if let cellar = path.range(of: "/Cellar/") {
            let link = String(path[..<cellar.lowerBound]) + "/bin/domo"
            if FileManager.default.isExecutableFile(atPath: link) { return URL(fileURLWithPath: link) }
        }
        return running.standardizedFileURL
    }

    /// The path this process was started by, unresolved: `~/.local/bin/domo` stays the link
    /// rather than the app bundle it points into, so the registered command survives app moves.
    public static func invokedExecutable(arguments: [String] = CommandLine.arguments,
                                         environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let first = arguments.first, !first.isEmpty else { return Bundle.main.executableURL }
        if first.contains("/") {
            let url = first.hasPrefix("/") ? URL(fileURLWithPath: first)
                : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(first)
            return url.standardizedFileURL
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(first)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.standardizedFileURL }
        }
        return Bundle.main.executableURL
    }

    /// The `domo` for the app to register, most stable path first: `DOMOVY_DOMO_PATH`, the
    /// `domo` on PATH (Domovy's own link or Homebrew's), then the copy inside the app bundle.
    /// - Parameter linked: Domovy's own `domo` link, when the caller knows it (a custom home keeps it inside).
    public static func installedDomo(linked: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main) -> URL? {
        if let path = environment["DOMOVY_DOMO_PATH"], FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        if let linked, FileManager.default.isExecutableFile(atPath: linked.path) { return linked }
        if let onPath = ExternalTool.locate("domo", environment: environment) { return onPath }
        return bundledDomo(bundle: bundle)
    }

    /// The `domo` shipped inside Domovy.app (Contents/Helpers, put there by the build).
    public static func bundledDomo(bundle: Bundle = .main) -> URL? {
        [bundle.bundleURL.appendingPathComponent("Contents/Helpers/domo"), bundle.bundleURL.appendingPathComponent("Contents/MacOS/domo")]
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// `domo mcp`, with `--root` for a custom home so a fixture stays a fixture.
    public static func serverCommand(domo: URL, home: URL, isCustomHome: Bool) -> [String] {
        [domo.path, "mcp"] + (isCustomHome ? ["--root", home.standardizedFileURL.path] : [])
    }
}
