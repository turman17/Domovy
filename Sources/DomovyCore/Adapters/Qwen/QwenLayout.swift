import Foundation

/// Paths of Qwen Code, read from QwenLM/qwen-code@09b8135e (CLI 0.28.3; docs/research/agent_storage_formats.md,
/// Q9; not verified on a real install). Permalink base:
/// https://github.com/QwenLM/qwen-code/blob/09b8135e6929df2e7f6a5cee8e55c47980b5f92e/
///
/// - The global folder is `~/.qwen` (`QWEN_HOME` moves it; packages/core/src/config/storage.ts#L193-L203).
///   `projects/`, `tmp/` and `resources/` live under the runtime folder, which is the global one
///   unless `QWEN_RUNTIME_DIR` says otherwise (storage.ts#L169-L191).
/// - A session is `projects/<slug>/chats/<uuid>.jsonl`, the slug being the project path with every
///   character other than a letter or digit replaced by `-` (packages/core/src/utils/paths.ts#L388-L392,
///   storage.ts#L619-L623); the name matches `^[0-9a-fA-F-]{32,36}\.jsonl$` (services/sessionService.ts#L547).
/// - Sidecars next to it: `<id>.runtime.json`, `.worktree.json`, `.pr.json`, `.title.json`,
///   `.branch.json`, `.artifacts.json`, `.goal.json` (config/config.ts#L8233-L8246) and
///   `<id>.ledger.jsonl` (sessionService.ts#L1210-L1217).
/// - Qwen archives a session by renaming the transcript and every sidecar but `.runtime.json`
///   into `chats/archive/` (sessionService.ts#L1039-L1047, #L2198-L2310, #L4628-L4760).
/// - Other per-session data: `projects/<slug>/subagents/<id>/` (agents/agent-transcript.ts#L66-L90),
///   `file-history/<id>/` in the global folder and `resources/<id>/` in the runtime folder
///   (sessionService.ts#L2019-L2023, utils/sessionStorageUtils.ts#L813-L821).
/// - Running sessions: `sessions/<pid>.json` in the global folder (services/session-registry.ts#L188-L236,
///   #L322) and `<runtime>/tmp/session-writer-locks/<id>.lock` (services/session-writer-lease.ts#L1709-L1719).
struct QwenLayout: Sendable {
    /// `~/.qwen`.
    let root: URL
    /// The runtime folder; `root` by default.
    let runtime: URL

    var projects: URL { runtime.appendingPathComponent("projects", isDirectory: true) }
    var registry: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    var writerLocks: URL { runtime.appendingPathComponent("tmp/session-writer-locks", isDirectory: true) }
    var fileHistory: URL { root.appendingPathComponent("file-history", isDirectory: true) }
    var resources: URL { runtime.appendingPathComponent("resources", isDirectory: true) }
    var tmp: URL { runtime.appendingPathComponent("tmp", isDirectory: true) }

    /// Sidecars Qwen keeps next to a transcript, as `<id><suffix>`.
    static let sidecars = [".title.json", ".artifacts.json", ".branch.json", ".goal.json", ".pr.json", ".worktree.json", ".ledger.jsonl"]
    /// Stays in `chats/` when Qwen archives a session (sessionService.ts#L2198-L2310).
    static let runtimeSidecar = ".runtime.json"

    /// Entries Qwen needs to run (storage.ts#L15-L24, #L205-L226, #L340-L345, #L640-L641, #L764-L769).
    static let protectedEntries: Set<String> = [
        "settings.json", "oauth_creds.json", "google_accounts.json", "mcp-oauth-tokens.json", "installation_id", "memory.md",
        "commands", "skills", "extensions", "workflows", "plans", "bin", "ide", "arena", "audits", "sessions",
    ]

    static func isSessionFile(_ name: String) -> Bool {
        guard name.hasSuffix(".jsonl") else { return false }
        let stem = name.dropLast(6)
        return (32...36).contains(stem.count) && stem.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    /// Never planned: the global entries above, a project's `memory/` and its
    /// `session-organization.v1.json` (list groups and pins).
    func isProtected(_ url: URL) -> Bool {
        if let relative = FileSystem.relativePath(of: url, under: projects) {
            let parts = relative.split(separator: "/").map(String.init)
            return parts.count < 2 || parts[1] == "memory" || parts[1] == "session-organization.v1.json"
        }
        guard let relative = FileSystem.relativePath(of: url, under: root) else { return false }
        guard let first = relative.split(separator: "/").first.map(String.init) else { return true }
        return Self.protectedEntries.contains(first)
    }

    /// One transcript and where it sits.
    struct Chat: Sendable {
        let id: String
        let file: URL
        /// `projects/<slug>`.
        let project: URL
        let isArchived: Bool

        var folder: URL { file.deletingLastPathComponent() }
        func sidecar(_ suffix: String) -> URL { folder.appendingPathComponent(id + suffix) }
    }

    func chats() -> [Chat] {
        var result: [Chat] = []
        for project in FileSystem.children(of: projects) where FileSystem.isDirectory(project) {
            let chats = project.appendingPathComponent("chats", isDirectory: true)
            for (folder, archived) in [(chats, false), (chats.appendingPathComponent("archive", isDirectory: true), true)] {
                for file in FileSystem.children(of: folder) where Self.isSessionFile(file.lastPathComponent) {
                    let id = String(file.lastPathComponent.dropLast(6))
                    guard SafeID.isSafe(id) else { continue }
                    result.append(Chat(id: id, file: file.standardizedFileURL, project: project.standardizedFileURL, isArchived: archived))
                }
            }
        }
        return result
    }

    /// Chats under the old Gemini-style `tmp/<sha256>/chats/`, which Qwen 0.28 no longer reads
    /// (no reader or migration found; only a stale comment at sessionService.ts#L943).
    func legacyChats() -> [URL] {
        FileSystem.children(of: tmp).filter { folder in
            folder.lastPathComponent.count == 64 && FileSystem.isDirectory(folder.appendingPathComponent("chats", isDirectory: true))
        }.map { $0.appendingPathComponent("chats", isDirectory: true) }
    }

    func probe() -> AdapterStatus {
        guard FileSystem.isDirectory(root) else { return .notInstalled }
        if FileSystem.exists(projects), !FileSystem.isDirectory(projects) {
            return .readOnly(reason: "~/.qwen/projects is not a folder, which Domovy does not know from any Qwen Code version.")
        }
        // Every transcript's first record must carry its own id: the layout Domovy read from Qwen's source.
        for chat in chats().prefix(50) {
            guard let first = FileSessions.records(in: chat.file, maxBytes: 64 * 1024).first else { continue }
            guard first["sessionId"] as? String == chat.id, first["type"] is String else {
                return .readOnly(reason: "A Qwen Code chat (\(chat.file.lastPathComponent)) does not have the record layout Domovy knows from Qwen Code 0.28, so it only lists what it can read.")
            }
        }
        return .ready
    }
}
