import Foundation

/// One project folder under `~/.gemini/tmp/` and its chats, read once.
struct GeminiProject: Sendable {
    struct Chat: Sendable {
        let file: URL
        let header: GeminiChat.Header
        let lastActive: Date
    }

    let folder: URL
    /// The project's own path, when known.
    let path: String?
    /// `projects.json` maps `path` to this folder, so Gemini CLI started there finds these chats.
    let isRegistered: Bool
    let chats: [Chat]
    /// Typed prompts per session id, from `logs.json`.
    private let prompts: [String: Int]

    /// `logs.json`: a JSON array of `{sessionId, messageId, timestamp, type, message}`.
    var promptLog: URL { folder.appendingPathComponent("logs.json") }

    init(folder: URL, registry: [String: String]) {
        self.folder = folder.standardizedFileURL
        let path = GeminiLayout.projectPath(of: folder, registry: registry)
        self.path = path
        self.isRegistered = path.map { registry[$0] == folder.lastPathComponent } ?? false
        self.chats = GeminiLayout.chatFiles(in: folder).map { file in
            Chat(file: file, header: GeminiChat.readHeader(of: file), lastActive: FileSystem.modificationDate(of: file) ?? .distantPast)
        }
        self.prompts = Self.promptCounts(in: folder.appendingPathComponent("logs.json"))
    }

    /// The chat's session id when no other chat of this project shares it, so the files Gemini
    /// CLI keys by it belong to this chat alone.
    func ownedID(of chat: Chat) -> String? {
        guard let id = chat.header.sessionID, GeminiLayout.isSafeComponent(id) else { return nil }
        return chats.filter { $0.header.sessionID == id }.count == 1 ? id : nil
    }

    /// No other chat file of the project ends in the same 8 characters.
    func hasUniqueShortID(_ chat: Chat) -> Bool {
        guard let short = GeminiLayout.shortID(ofChatNamed: chat.file.lastPathComponent) else { return false }
        return chats.filter { GeminiLayout.shortID(ofChatNamed: $0.file.lastPathComponent) == short }.count == 1
    }

    func promptCount(for id: String) -> Int? {
        prompts[id]
    }

    /// Chats Gemini CLI's sweep removes the next time it starts here regardless of age, with
    /// the reason: chats without messages, and chats beyond `maxCount`.
    func dueForSweep(_ settings: GeminiSettings) -> [URL: String] {
        guard settings.isEnabled else { return [:] }
        var due: [URL: String] = [:]
        let main = chats.filter { $0.header.kind != "subagent" }
        for chat in main where !chat.header.hasMessages {
            due[chat.file] = "Gemini CLI removes chats without messages the next time it starts in this project."
        }
        if let limit = settings.maxCount {
            let kept = main.filter(\.header.hasMessages).sorted { $0.lastActive > $1.lastActive }
            for (index, chat) in kept.enumerated() where index >= limit {
                due[chat.file] = "Gemini CLI keeps the newest \(limit) chats of each project; this is number \(index + 1)."
            }
        }
        return due
    }

    /// Every chat the sweep would remove if Gemini CLI started in this project now.
    func sweptOnStart(_ settings: GeminiSettings, now: Date) -> Set<URL> {
        var swept = Set(dueForSweep(settings).keys)
        if let maxAge = settings.maxAge {
            for chat in chats where chat.header.kind != "subagent" && chat.lastActive.addingTimeInterval(maxAge) < now {
                swept.insert(chat.file)
            }
        }
        return swept
    }

    /// Reads only `sessionId` of each entry; files over 8 MB are left unread.
    private static func promptCounts(in url: URL) -> [String: Int] {
        guard FileSystem.size(of: url) < 8_000_000, let data = try? Data(contentsOf: url),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var counts: [String: Int] = [:]
        for entry in entries {
            if let id = entry["sessionId"] as? String { counts[id, default: 0] += 1 }
        }
        return counts
    }
}
