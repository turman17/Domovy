import Foundation

/// Paths inside `~/.copilot` for GitHub Copilot CLI, from GitHub's config-directory reference
/// (assumed: not installed where Domovy was developed). A session is one folder,
/// `session-state/<id>/`, holding `events.jsonl` plus plans, checkpoints and tracked files.
/// `session-store.db` is a SQLite index for search and `/chronicle`.
struct CopilotLayout: Sendable {
    let root: URL

    var sessionState: URL { root.appendingPathComponent("session-state", isDirectory: true) }
    /// Search index. Rebuilt by `/chronicle reindex`, which also syncs to the user's account.
    var sessionStore: URL { root.appendingPathComponent("session-store.db") }
    var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    var commandHistory: URL { root.appendingPathComponent("command-history-state", isDirectory: true) }
    /// Older versions kept one JSON file per session here (assumed).
    var legacyHistory: URL { root.appendingPathComponent("history-session-state", isDirectory: true) }

    func folder(of id: String) -> URL {
        sessionState.appendingPathComponent(id, isDirectory: true)
    }

    /// Entries Copilot CLI needs to run (assumed names). Domovy never plans changes to them.
    static let protectedEntries: Set<String> = [
        "config.json", "mcp-config.json", "permissions-config.json", "agents", "skills", "hooks", "extensions",
        "session-store.db", "session-store.db-wal", "session-store.db-shm",
    ]

    func isProtected(_ url: URL) -> Bool {
        guard let relative = FileSystem.relativePath(of: url, under: root) else { return false }
        guard let first = relative.split(separator: "/").first.map(String.init) else { return true }
        return Self.protectedEntries.contains(first)
    }

    func probe() -> AdapterStatus {
        guard FileSystem.isDirectory(root) else { return .notInstalled }
        if FileSystem.exists(sessionState), !FileSystem.isDirectory(sessionState) {
            return .readOnly(reason: "~/.copilot/session-state is not a folder, which Domovy does not know from any Copilot CLI version.")
        }
        return .ready
    }

    /// Session folders: a safe id with an `events.jsonl` inside. Anything else is left alone.
    func sessionFolders() -> [URL] {
        FileSystem.children(of: sessionState).filter { url in
            let name = url.lastPathComponent
            return FileSystem.isDirectory(url) && Self.isSafeID(name) && FileSystem.exists(url.appendingPathComponent("events.jsonl"))
        }
    }

    static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && !id.hasPrefix(".") && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}
