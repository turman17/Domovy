import Foundation

/// Paths inside `~/.claude` as documented in docs/research/agent_storage_formats.md.
/// Everything here is relative to the injected config directory; nothing assumes `~`.
struct ClaudeCodeLayout: Sendable {
    let root: URL

    var projects: URL { root.appendingPathComponent("projects", isDirectory: true) }
    var fileHistory: URL { root.appendingPathComponent("file-history", isDirectory: true) }
    var uploads: URL { root.appendingPathComponent("uploads", isDirectory: true) }
    var devMods: URL { root.appendingPathComponent("dev-mods", isDirectory: true) }
    var sessionEnv: URL { root.appendingPathComponent("session-env", isDirectory: true) }
    var security: URL { root.appendingPathComponent("security", isDirectory: true) }
    var agentSDKEnvironment: URL { security.appendingPathComponent("agent-sdk-venv", isDirectory: true) }
    /// Worktrees of agent sessions, when Claude Code keeps any here. The documented place is
    /// `<repo>/.claude/worktrees/`, inside each project, which Domovy does not scan.
    var worktrees: URL { root.appendingPathComponent("worktrees", isDirectory: true) }
    var sessions: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    var daemonRoster: URL { root.appendingPathComponent("daemon", isDirectory: true).appendingPathComponent("roster.json") }
    var history: URL { root.appendingPathComponent("history.jsonl") }
    var settings: URL { root.appendingPathComponent("settings.json") }

    /// Folders and files the agent needs to run. Never part of any plan (CLAUDE.md safety rule 6).
    static let protectedRootEntries: Set<String> = [
        "plugins", "settings.json", "skills", "keybindings.json", "CLAUDE.md",
        ".credentials.json", "agent-memory", "jobs", "daemon",
    ]

    /// Per-project folder the sweep never deletes and neither do we.
    static let protectedProjectEntries: Set<String> = ["memory"]

    /// True when `url` must never be moved or edited.
    func isProtected(_ url: URL) -> Bool {
        guard let relative = FileSystem.relativePath(of: url, under: root) else { return false }
        let parts = relative.split(separator: "/").map(String.init)
        guard let first = parts.first else { return true } // the root itself
        if Self.protectedRootEntries.contains(first) { return true }
        // projects/<slug>/memory/...
        if first == "projects", parts.count >= 3, Self.protectedProjectEntries.contains(parts[2]) { return true }
        return false
    }

    // MARK: Transcript naming

    private static let uuidPattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    private static let transcriptRegex = try? NSRegularExpression(pattern: "^(\(uuidPattern))\\.jsonl$")
    private static let setAsideRegex = try? NSRegularExpression(
        pattern: "^(\(uuidPattern))(\\.orphaned-[^/]+\\.jsonl|\\.jsonl\\.superseded-[^/]+)$"
    )

    /// Session id if `name` is a primary transcript `<uuid>.jsonl`.
    static func sessionID(ofTranscriptNamed name: String) -> String? {
        firstGroup(transcriptRegex, in: name)
    }

    /// Session id if `name` is an `.orphaned-*` or `.superseded-*` set-aside copy.
    static func sessionID(ofSetAsideCopyNamed name: String) -> String? {
        firstGroup(setAsideRegex, in: name)
    }

    static func isUUID(_ name: String) -> Bool {
        UUID(uuidString: name) != nil
    }

    private static func firstGroup(_ regex: NSRegularExpression?, in text: String) -> String? {
        guard let regex,
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).lowercased()
    }

    // MARK: Probe

    /// Decides whether this layout is one we understand. Never guesses: anything unexpected
    /// among the transcript files makes the adapter read-only.
    func probe() -> AdapterStatus {
        guard FileSystem.exists(root) else { return .notInstalled }
        guard FileSystem.isDirectory(projects) else {
            return .readOnly(reason: "Expected a projects/ folder inside \(root.lastPathComponent) and found none.")
        }
        var unexpected = 0
        for slug in FileSystem.children(of: projects) where FileSystem.isDirectory(slug) {
            for entry in FileSystem.children(of: slug) {
                let name = entry.lastPathComponent
                if FileSystem.isDirectory(entry) {
                    // <uuid>/ companions and memory/ are known; anything else is tolerated but not planned.
                    continue
                }
                if name.hasSuffix(".jsonl") || name.contains(".jsonl.") {
                    if Self.sessionID(ofTranscriptNamed: name) == nil, Self.sessionID(ofSetAsideCopyNamed: name) == nil {
                        unexpected += 1
                    }
                }
            }
        }
        if unexpected > 0 {
            return .readOnly(reason: "Found \(unexpected) transcript file\(unexpected == 1 ? "" : "s") with a name Domovy does not recognise. This may be a newer Claude Code layout; nothing will be changed until it is understood.")
        }
        return .ready
    }
}
