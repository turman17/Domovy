import Foundation

/// Agents that keep one JSON-lines file per session under `<root>/<sessions>/<project slug>/`,
/// whose first line is a header naming the session (Auggie, Factory Droid). What differs per
/// agent is here; `JSONLSessionAdapter` does the rest. Neither has a non-interactive delete, so
/// Domovy moves the files itself with the agent quit.
public struct JSONLSessionFlavor: Sendable, Hashable {
    public let kind: AgentKind
    /// The agent's folder below home (`.augment`).
    let folder: String
    /// The sessions folder below the agent's folder (`sessions-v2`).
    let sessionsFolder: String
    /// `type` of the first record.
    let headerType: String
    /// The highest header `version` Domovy knows; `nil` when the header has no version.
    let maxVersion: Int?
    /// Files or folders next to `<id>.jsonl` that belong to the session, as `<id><suffix>`.
    let companions: [Companion]
    /// Folders below the agent's folder that only Domovy's footprint measures.
    let legacyFolders: [String]
    let matcher: ProcessMatcher
    /// Said in every delete plan: how the agent itself deletes, or why Domovy moves the files.
    let deleteRemark: String
    /// Extra consequences of a delete (Factory's cloud copy).
    let extraDeleteRemarks: [String]

    struct Companion: Sendable, Hashable {
        let suffix: String
        let isFolder: Bool
        let note: String
    }

    var appName: String { kind.displayName }

    /// Auggie (Augment CLI) 1.2.2, read from the shipped npm bundle `@augmentcode/auggie@1.2.2`
    /// (`auggie-v2.mjs`, build 6f24c7b3, 2026-11-17; docs/research/agent_storage_formats.md, Q9).
    /// It is a fork of pi's coding agent:
    /// - The folder is `~/.augment` (`AUGMENT_CACHE_DIR`, `AUGGIE_CODING_AGENT_DIR` move it; not followed).
    /// - A session is `sessions-v2/--<cwd without its leading slash, "/" "\" ":" as "-">--/<id>.jsonl`
    ///   (function `Bb`), created as `${sessionId}.jsonl` (`newSession`, `fork`).
    /// - The first line is `{type: "session", version: 3, id, timestamp, cwd, parentSession?}`; a file
    ///   whose first line is not that is no session (`ade`, `HZs`). Names are `session_info` records.
    /// - Pasted images go to `<id>.files/` next to it. Auggie's own delete (session picker only) runs
    ///   `trash <file>` (or unlinks it) and then removes `<id>.files/` (`ava`, `lva`).
    /// - `auggie session list` only lists; there is no delete command.
    public static let auggie = JSONLSessionFlavor(
        kind: .auggie, folder: ".augment", sessionsFolder: "sessions-v2", headerType: "session", maxVersion: 3,
        companions: [Companion(suffix: ".files", isFolder: true, note: "Pasted images of the session")],
        legacyFolders: ["sessions"],
        matcher: ProcessMatcher(appName: "Auggie", names: ["auggie"], quitAdvice: "Quit Auggie to change its sessions.",
                                argumentMarkers: ["@augmentcode/auggie", "auggie-v2.mjs"]),
        deleteRemark: "Auggie deletes a session from its session picker by moving the file to the Trash and removing its .files folder; it has no command for that. Domovy does the same while Auggie is quit.",
        extraDeleteRemarks: [])

    /// Factory Droid. Closed source; read from Factory's own `session-navigation` skill
    /// (factory-ai/factory-plugins@8f9ff232^, plugins/core/skills/session-navigation/SKILL.md#L17-L36, #L118)
    /// and a third-party reader checked against droid 0.126.0 (sageox/ox v0.26.0, cmd/ox-adapter-droid):
    /// - A session is `~/.factory/sessions/<cwd with "/" as "-">/<uuid>.jsonl` plus `<uuid>.settings.json`.
    /// - The first line is `{type: "session_start", id, title, cwd}`; the rest are
    ///   `{type: "message", message: {role, content: [text | thinking | tool_use | tool_result | image]}}`.
    /// - No local delete command was found. Sessions may also sync to Factory's cloud.
    public static let factoryDroid = JSONLSessionFlavor(
        kind: .factoryDroid, folder: ".factory", sessionsFolder: "sessions", headerType: "session_start", maxVersion: nil,
        companions: [Companion(suffix: ".settings.json", isFolder: false, note: "Session settings and token counts")],
        legacyFolders: [],
        matcher: ProcessMatcher(appName: "Factory Droid", names: ["droid"], quitAdvice: "Quit Droid to change its sessions."),
        deleteRemark: "Factory Droid has no command to delete a session, so Domovy moves its two files itself while Droid is quit.",
        extraDeleteRemarks: ["Factory may keep a copy of this session in its cloud (cloud session sync). Deleting it here does not delete that copy; remove it in Factory's web app too."])

    /// Title: the newest `session_info` name (Auggie) or the header's `title` (Factory), else
    /// the first user prompt.
    func title(header: [String: Any], records: [[String: Any]], tail: [[String: Any]]) -> String? {
        if let named = (records + tail).last(where: { $0["type"] as? String == "session_info" })?["name"] as? String,
           let title = FileSessions.title(named) {
            return title
        }
        if let title = FileSessions.title(header["title"] as? String) { return title }
        for record in records where record["type"] as? String == "message" {
            guard let message = record["message"] as? [String: Any], message["role"] as? String == "user" else { continue }
            if let title = FileSessions.title(FileSessions.text(of: message["content"])) { return title }
        }
        return nil
    }

    /// `{type: message, message: {role, content}}`: text parts, and tool calls as `toolCall`
    /// (Auggie, `{type: toolCall, name}`) or `tool_use` (Factory, `{type: tool_use, name}`).
    static func message(_ record: [String: Any], index: Int) -> TranscriptMessage? {
        guard record["type"] as? String == "message", let message = record["message"] as? [String: Any] else { return nil }
        let role: TranscriptMessage.Role
        switch message["role"] as? String {
        case "user": role = .user
        case "assistant": role = .assistant
        default: return nil
        }
        var blocks: [TranscriptMessage.Block] = []
        if let text = FileSessions.text(of: message["content"]) { blocks.append(.text(text)) }
        for case let part as [String: Any] in message["content"] as? [Any] ?? [] {
            let type = part["type"] as? String
            if type == "toolCall" || type == "tool_use" { blocks.append(.toolCall((part["name"] as? String) ?? "Tool")) }
        }
        guard !blocks.isEmpty else { return nil }
        return TranscriptMessage(id: (record["id"] as? String) ?? "j\(index)", role: role,
                                 timestamp: FileSessions.date(record["timestamp"] as? String), blocks: blocks)
    }
}

/// Where one flavor's sessions are.
struct JSONLSessionLayout: Sendable {
    let flavor: JSONLSessionFlavor
    /// The agent's folder (`~/.augment`).
    let root: URL

    var sessions: URL { root.appendingPathComponent(flavor.sessionsFolder, isDirectory: true) }

    struct Chat: Sendable {
        let id: String
        let file: URL
        var folder: URL { file.deletingLastPathComponent() }
    }

    /// Only files two levels below the sessions folder are ever planned; everything else in the
    /// agent's folder (sign-in, settings, skills, plugins) is never touched.
    func isProtected(_ url: URL) -> Bool {
        guard let relative = FileSystem.relativePath(of: url, under: sessions) else { return true }
        return relative.split(separator: "/").count < 2
    }

    func chats() -> [Chat] {
        FileSystem.children(of: sessions).filter(FileSystem.isDirectory).flatMap { project in
            FileSystem.children(of: project).compactMap { file -> Chat? in
                guard file.pathExtension == "jsonl" else { return nil }
                let id = file.deletingPathExtension().lastPathComponent
                guard SafeID.isSafe(id), !FileSystem.isDirectory(file) else { return nil }
                return Chat(id: id, file: file.standardizedFileURL)
            }
        }
    }

    func companion(_ chat: Chat, _ companion: JSONLSessionFlavor.Companion) -> URL {
        chat.folder.appendingPathComponent(chat.id + companion.suffix, isDirectory: companion.isFolder)
    }

    /// The header of a session file, or `nil` when the first line is not one.
    func header(of file: URL) -> [String: Any]? {
        guard let first = FileSessions.records(in: file, maxBytes: 64 * 1024).first,
              first["type"] as? String == flavor.headerType, first["id"] is String else { return nil }
        return first
    }

    func probe() -> AdapterStatus {
        guard FileSystem.isDirectory(root) else { return .notInstalled }
        let name = "~/\(flavor.folder)/\(flavor.sessionsFolder)"
        if FileSystem.exists(sessions), !FileSystem.isDirectory(sessions) {
            return .readOnly(reason: "\(name) is not a folder, which Domovy does not know from any \(flavor.appName) version.")
        }
        for chat in chats().prefix(50) where FileSystem.size(of: chat.file) > 0 {
            guard let header = header(of: chat.file) else {
                return .readOnly(reason: "A \(flavor.appName) session (\(chat.file.lastPathComponent)) does not start with the \"\(flavor.headerType)\" record Domovy knows, so it only measures the folder.")
            }
            guard header["id"] as? String == chat.id else {
                return .readOnly(reason: "A \(flavor.appName) session file is not named after its session id, a layout Domovy does not know, so it only measures the folder.")
            }
            if let max = flavor.maxVersion, let version = header["version"] as? Int, version > max {
                return .readOnly(reason: "A \(flavor.appName) session has format version \(version); Domovy knows up to \(max), so it only lists what it can read.")
            }
        }
        return .ready
    }
}
