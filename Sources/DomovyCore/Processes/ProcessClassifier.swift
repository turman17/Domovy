import Foundation

/// What a process is to Domovy.
public enum ProcessKind: String, Codable, Sendable, CaseIterable {
    /// The agent itself: the topmost process of an agent's tree (`claude`, `Codex`, `Cursor`).
    case agent
    /// Another process of the same agent (`Claude Helper`, `codex-code-mode-host`).
    case helper
    /// Likely an MCP server: a child started with an MCP package or script. A heuristic.
    case mcpServer
    /// Anything else the agent started (a shell, a test run, a language server).
    case child

    public var displayName: String {
        switch self {
        case .agent: "Agent"
        case .helper: "Helper"
        case .mcpServer: "MCP server"
        case .child: "Child"
        }
    }
}

/// Names agents by their processes and spots likely MCP servers. Arguments are only matched
/// against patterns here; they are never kept, logged or shown.
enum ProcessClassifier {
    /// The agent a process belongs to by its own name, or `nil`.
    static func agent(of process: RawProcess, arguments: () -> [String]?) -> AgentKind? {
        if isSystem(process) { return nil }
        let name = process.name
        let lower = name.lowercased()
        if name == "claude" { return .claudeCode }
        if ClaudeDesktopRegistry.processMatcher.matches(name) { return .claudeDesktop }
        if lower == "codex" || lower.hasPrefix("codex-") { return .codex }
        if name == "Cursor" || lower.hasPrefix("cursor helper") { return .cursor }
        if lower == "ollama" || lower.hasPrefix("ollama ") { return .ollama }
        if lower == "lm studio" || lower.hasPrefix("lm studio helper") || lower == "lms" { return .lmStudio }
        // `agy` is the Antigravity CLI (verified); the app's names are assumed.
        if AntigravityAdapter.processMatcher.matches(name) { return .antigravity }
        // `gemini`, lowercase only: Google's `Gemini` chat app is not Gemini CLI.
        if name == "gemini" { return .gemini }
        guard interpreters.contains(lower), let arguments = arguments() else { return nil }
        // Claude Code installed with npm runs as `node …/@anthropic-ai/claude-code/cli.js`.
        if arguments.contains(where: { $0.contains("@anthropic-ai/claude-code") }) { return .claudeCode }
        // Gemini CLI runs as `node …/@google/gemini-cli/bundle/gemini.js` (verified, Homebrew).
        if arguments.contains(where: { $0.contains("@google/gemini-cli") }) { return .gemini }
        return nil
    }

    /// Where an orphan most likely came from, by its executable path: under an agent's folder
    /// or app bundle. `nil` when nothing says.
    static func agentHint(path: String?) -> AgentKind? {
        guard let path else { return nil }
        if path.contains("/.claude/") || path.contains("/Claude.app/") { return path.contains("/Claude.app/") ? .claudeDesktop : .claudeCode }
        if path.contains("/.codex/") || path.contains("/Codex.app/") || path.contains("/ChatGPT.app/") { return .codex }
        if path.contains("/.cursor/") || path.contains("/Cursor.app/") { return .cursor }
        if path.contains("/.gemini/antigravity") || path.contains("/Antigravity.app/") { return .antigravity }
        if path.contains("/.gemini/") || path.contains("/gemini-cli/") { return .gemini }
        return nil
    }

    /// Runtimes MCP servers are usually started with; only their arguments are read. Shells
    /// are left out: their command lines mention whatever they run, and the server they start
    /// shows up as their child.
    static let interpreters: Set<String> = [
        "node", "nodejs", "bun", "deno", "npx", "npm", "pnpm", "yarn", "uv", "uvx", "pipx",
        "python", "python3", "java", "ruby", "docker", "go",
    ]

    static func isInterpreter(_ name: String) -> Bool {
        let lower = name.lowercased()
        return interpreters.contains(lower) || lower.hasPrefix("python3.")
    }

    /// Processes of macOS itself, which Domovy never classifies or signals.
    static func isSystem(_ process: RawProcess) -> Bool {
        guard process.pid > 1 else { return true }
        guard let path = process.executablePath else { return false }
        return ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/bin/", "/usr/bin/"].contains { path.hasPrefix($0) }
    }

    private static let mcpPattern = try? NSRegularExpression(
        pattern: "modelcontextprotocol|(?:^|[^a-z])mcp|mcp(?:[^a-z]|$)", options: [.caseInsensitive]
    )

    /// A name or argument that says MCP: `mcp-server-github`, `@modelcontextprotocol/…`,
    /// `@playwright/mcp`, `xcodebuildmcp`, `mcp_server.py`. Flags are skipped.
    static func mentionsMCP(_ token: String) -> Bool {
        guard !token.hasPrefix("-"), let mcpPattern else { return false }
        return mcpPattern.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)) != nil
    }

    /// A likely MCP server: its name or one of its arguments mentions MCP.
    static func looksLikeMCPServer(_ process: RawProcess, arguments: [String]?) -> Bool {
        mentionsMCP(process.name) || (arguments ?? []).contains(where: mentionsMCP)
    }

    /// A short label safe to show: the process name plus, for an MCP server, the package or
    /// script name (`node @playwright/mcp`, `python mcp_server`). Never a full command line:
    /// anything that looks like a URL, an option or a value is left out.
    static func displayName(_ process: RawProcess, kind: ProcessKind, arguments: [String]?) -> String {
        // Tools like npm rewrite their title into one argument ("npm exec @playwright/mcp@latest").
        let tokens = (arguments ?? []).lazy.flatMap { $0.split(separator: " ").map(String.init) }
        guard kind == .mcpServer, !mentionsMCP(process.name), let label = tokens.filter(mentionsMCP).compactMap(packageLabel).first else {
            return process.name
        }
        return "\(process.name) \(label)"
    }

    private static let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@._/+-")

    /// `/x/node_modules/@scope/mcp-thing@1.2.0/dist/index.js` → `@scope/mcp-thing`;
    /// `mcp-server-github@latest` → `mcp-server-github`; `/x/my_mcp.py` → `my_mcp`.
    static func packageLabel(_ token: String) -> String? {
        guard !token.contains("://"), !token.contains("="), !token.contains("?"), !token.contains("#"),
              token.unicodeScalars.allSatisfy(safeCharacters.contains) else { return nil }
        let parts = token.split(separator: "/").map(String.init)
        // The path component that mentions MCP, with its scope when it has one.
        guard let index = parts.lastIndex(where: mentionsMCP) else { return nil }
        var label = parts[index]
        if index > 0, parts[index - 1].hasPrefix("@") { label = parts[index - 1] + "/" + label }
        else if label.hasPrefix("@"), index + 1 < parts.count { label += "/" + parts[index + 1] }
        if let at = label.dropFirst().firstIndex(of: "@") { label = String(label[..<at]) }
        for suffix in [".js", ".mjs", ".cjs", ".ts", ".py"] where label.hasSuffix(suffix) {
            label = String(label.dropLast(suffix.count))
        }
        return label.isEmpty ? nil : String(label.prefix(48))
    }
}
