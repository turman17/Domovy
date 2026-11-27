import Foundation

/// One Antigravity store under `~/.gemini`: `antigravity-cli/` for the `agy` CLI (verified on
/// 1.5.8) and `antigravity/` for the desktop app (assumed, from the research doc). Both keep
/// `conversations/<id>.db` (SQLite, with `-wal`/`-shm`) and `brain/<id>/`; the app also keeps
/// `annotations/<id>.pbtxt` and `presence/<id>.lock` while a conversation is open.
struct AntigravityStore: Sendable {
    let root: URL
    /// "Antigravity CLI" or "Antigravity".
    let name: String
    /// The CLI store's layout is verified, so Domovy deletes and archives there. The app's is
    /// assumed, so it stays read-only.
    let isVerified: Bool

    var conversations: URL { root.appendingPathComponent("conversations", isDirectory: true) }
    var brain: URL { root.appendingPathComponent("brain", isDirectory: true) }
    var annotations: URL { root.appendingPathComponent("annotations", isDirectory: true) }
    var presence: URL { root.appendingPathComponent("presence", isDirectory: true) }
    /// CLI: `implicit/<id>.pb`, what Antigravity learned in a conversation.
    var implicit: URL { root.appendingPathComponent("implicit", isDirectory: true) }
    /// CLI: `conversation_summaries` with `title`, `workspace_uris`, `last_modified_time`.
    var summaries: URL { root.appendingPathComponent("conversation_summaries.db") }
    /// The summaries database and its `-wal` and `-shm`.
    var summariesFiles: [URL] { ["", "-wal", "-shm"].map { root.appendingPathComponent("conversation_summaries.db\($0)") } }
    /// CLI: `{"conversations": {"<id>": {"summary": {"Title", "WorkspaceURIs", ...}, ...}}}`.
    var metadataCache: URL { root.appendingPathComponent("cache/conversation_metadata.json") }
    /// CLI prompt history: `{display, timestamp, workspace, conversationId?, type?}` per line.
    var history: URL { root.appendingPathComponent("history.jsonl") }

    /// Entries Antigravity needs to run. Domovy never plans changes to them.
    static let protectedEntries: Set<String> = [
        "settings.json", "antigravity-oauth-token", "installation_id", "bin", "builtin", "updater",
        "knowledge", "jetski_state.pbtxt", "mcp_config.json", "conversation_summaries.db", "cache", "skills",
    ]

    static func stores(in geminiHome: URL) -> [AntigravityStore] {
        [AntigravityStore(root: geminiHome.appendingPathComponent("antigravity-cli", isDirectory: true), name: "Antigravity CLI", isVerified: true),
         AntigravityStore(root: geminiHome.appendingPathComponent("antigravity", isDirectory: true), name: "Antigravity", isVerified: false)]
            .filter { FileSystem.isDirectory($0.root) }
    }

    /// One listing of `conversations/` and one read of `history.jsonl`, shared by every
    /// conversation of the store.
    struct Catalog: Sendable {
        /// The database and its `-wal`/`-shm` (or a legacy `.pb`), by conversation id.
        let files: [String: [URL]]
        /// Lines of `history.jsonl` per conversation id.
        let historyLines: [String: Int]
        /// The first prompt typed into each conversation, from `history.jsonl`: a title and
        /// workspace for conversations Antigravity has not summarized. Shown, never logged.
        let firstPrompts: [String: FirstPrompt]

        var ids: [String] { files.keys.sorted() }
    }

    struct FirstPrompt: Sendable {
        var display: String?
        var workspace: String?
    }

    func catalog() -> Catalog {
        var files: [String: [URL]] = [:]
        for url in FileSystem.children(of: conversations) {
            let name = url.lastPathComponent.lowercased()
            guard let dot = name.firstIndex(of: ".") else { continue }
            let id = String(name[..<dot])
            let suffix = name[dot...]
            guard ClaudeCodeLayout.isUUID(id), suffix == ".db" || suffix == ".pb" || suffix.hasPrefix(".db-") else { continue }
            files[id, default: []].append(url)
        }
        // Only ids with the database itself; a lone `-wal` is not a conversation.
        files = files.filter { _, urls in urls.contains { [".db", ".pb"].contains("." + $0.pathExtension.lowercased()) } }
        var history: [String: Int] = [:]
        var prompts: [String: FirstPrompt] = [:]
        if FileSystem.size(of: self.history) < 16_000_000, let data = try? Data(contentsOf: self.history) {
            // The file is appended to, so the first line of an id is its first prompt.
            for line in JSONLines.split(data).lines {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = (object["conversationId"] as? String)?.lowercased() else { continue }
                history[id, default: 0] += 1
                // Slash commands ("/model") say nothing about the conversation.
                guard object["type"] as? String != "command" else { continue }
                var prompt = prompts[id] ?? FirstPrompt()
                if prompt.display == nil { prompt.display = AntigravityIndex.clean(object["display"] as? String) }
                if prompt.workspace == nil, let workspace = object["workspace"] as? String, workspace.hasPrefix("/") {
                    prompt.workspace = workspace
                }
                prompts[id] = prompt
            }
        }
        return Catalog(files: files, historyLines: history, firstPrompts: prompts)
    }

    func isProtected(_ url: URL) -> Bool {
        guard let relative = FileSystem.relativePath(of: url, under: root),
              let first = relative.split(separator: "/").first.map(String.init) else { return false }
        return Self.protectedEntries.contains(first)
    }
}
