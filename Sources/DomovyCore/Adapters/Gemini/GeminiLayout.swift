import Foundation

/// Paths inside `~/.gemini` for Gemini CLI, as verified on 0.43.0 (docs/research). Each
/// project has a folder under `tmp/` named by `projects.json` (older versions: the sha256 of
/// the project path) with `chats/session-<date>T<HH-MM>-<first 8 of id>.jsonl`.
struct GeminiLayout: Sendable {
    let root: URL

    var tmp: URL { root.appendingPathComponent("tmp", isDirectory: true) }
    /// Shadow git repositories of file checkpoints, one per project.
    var history: URL { root.appendingPathComponent("history", isDirectory: true) }
    var settings: URL { root.appendingPathComponent("settings.json") }
    /// `{"projects": {"<project path>": "<folder name under tmp/>"}}`.
    var projectsRegistry: URL { root.appendingPathComponent("projects.json") }

    /// Entries Gemini CLI needs to run, plus Antigravity's folders, which share `~/.gemini`.
    static let protectedRootEntries: Set<String> = [
        "settings.json", "oauth_creds.json", "google_accounts.json", "installation_id", "projects.json",
        "trustedFolders.json", "state.json", "mcp-oauth-tokens.json", "GEMINI.md",
        "config", "extensions", "commands", "policies", "skills", "agents",
        "antigravity", "antigravity-cli",
    ]

    /// Folders inside a project folder that are not session ids.
    static let projectEntries: Set<String> = ["chats", "logs", "tool-outputs", "checkpoints"]

    func isProtected(_ url: URL) -> Bool {
        guard let relative = FileSystem.relativePath(of: url, under: root) else { return false }
        guard let first = relative.split(separator: "/").first.map(String.init) else { return true }
        return Self.protectedRootEntries.contains(first)
    }

    /// Installed when Gemini CLI left any of its own files here; `~/.gemini` alone may be
    /// Antigravity's.
    func probe() -> AdapterStatus {
        guard FileSystem.isDirectory(root) else { return .notInstalled }
        let markers = [tmp, history, settings, projectsRegistry, root.appendingPathComponent("oauth_creds.json")]
        guard markers.contains(where: { FileSystem.exists($0) }) else { return .notInstalled }
        if FileSystem.exists(tmp), !FileSystem.isDirectory(tmp) {
            return .readOnly(reason: "~/.gemini/tmp is not a folder, which Domovy does not know from any Gemini CLI version.")
        }
        return .ready
    }

    /// Project folders under `tmp/` that hold chats.
    func projectFolders() -> [URL] {
        FileSystem.children(of: tmp).filter { FileSystem.isDirectory($0.appendingPathComponent("chats", isDirectory: true)) }
    }

    /// `chats/session-*.jsonl` (and the older whole-JSON `session-*.json`) of one project.
    /// Subagent chats live one level deeper, in `chats/<parent session id>/`.
    static func chatFiles(in project: URL) -> [URL] {
        FileSystem.children(of: project.appendingPathComponent("chats", isDirectory: true)).filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix("session-") && (name.hasSuffix(".jsonl") || name.hasSuffix(".json")) && !FileSystem.isDirectory(url)
        }
    }

    /// The 8 characters after the last `-` of a chat file name; Gemini CLI deletes every file
    /// of a project that ends in them.
    static func shortID(ofChatNamed name: String) -> String? {
        let stem = name.hasSuffix(".jsonl") ? String(name.dropLast(6)) : name.hasSuffix(".json") ? String(name.dropLast(5)) : name
        guard let last = stem.split(separator: "-").last, last.count == 8 else { return nil }
        return String(last)
    }

    /// `2026-06-22T07-44` from `session-2026-06-22T07-44-a2a-serv.jsonl`.
    static func stamp(ofChatNamed name: String) -> String? {
        guard name.hasPrefix("session-") else { return nil }
        let parts = name.dropFirst("session-".count).split(separator: "-")
        guard parts.count >= 5 else { return nil }
        return parts.prefix(4).joined(separator: "-")
    }

    /// Path of the project folder by path, from `projects.json`.
    func registry() -> [String: String] {
        guard let data = try? Data(contentsOf: projectsRegistry),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = object["projects"] as? [String: String] else { return [:] }
        return projects
    }

    /// The project's path: `.project_root` in its folder, else the `projects.json` entry that
    /// names the folder. A legacy hash folder without either has no known path.
    static func projectPath(of folder: URL, registry: [String: String]) -> String? {
        let marker = folder.appendingPathComponent(".project_root")
        if let data = try? Data(contentsOf: marker), data.count < 4_096,
           let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           text.hasPrefix("/") {
            return text
        }
        return registry.first { $0.value == folder.lastPathComponent }?.key
    }

    /// A session id that is safe as one path component (Gemini CLI sanitises it the same way).
    static func isSafeComponent(_ id: String) -> Bool {
        !id.isEmpty && id != "." && id != ".." && !id.contains("/") && !projectEntries.contains(id)
    }
}
