import Foundation

/// Gemini Code Assist's chats, verified on extension 2.104 in VS Code 1.138 (Q8 of
/// docs/research/agent_storage_formats.md): they are not files but one JSON value of the global
/// `state.vscdb`, key `google.geminicodeassist`, member `geminiCodeAssist.chatThreads`:
/// `{<scope key>: {<thread uuid>: {id, title, create_time, update_time, ideContextFolderUris,
/// a2aTaskId, history [{entity, markdownText, traceId, …}], …}}}`. File checkpoints of a reply
/// are folders `globalStorage/google.geminicodeassist/chat_checkpoint_files/<traceId>/`.
struct GeminiCodeAssistIndex: Sendable {
    static let key = "google.geminicodeassist"
    static let threadsField = "geminiCodeAssist.chatThreads"
    static let extensionFolder = "google.geminicodeassist"

    struct Thread: Sendable {
        let id: String
        /// The member of `chatThreads` that holds it.
        let scope: String
        let title: String?
        let createdAt: Date?
        let updatedAt: Date?
        let project: String?
        let traceIDs: [String]
        let ranAgentMode: Bool
        /// Bytes of its JSON inside the value.
        let bytes: Int64
    }

    enum State: Sendable {
        case absent
        case known([Thread], valueBytes: Int64)
        case unknown(String)
    }

    static func load(_ database: URL) -> State {
        guard let data = VSCodeState.value(key, in: database) else { return .absent }
        let shape = "Gemini Code Assist's chats in state.vscdb have a shape Domovy does not know, so it only lists what it can read and changes nothing."
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unknown(shape) }
        guard let threads = object[threadsField] else { return .known([], valueBytes: Int64(data.count)) }
        guard let scopes = threads as? [String: Any] else { return .unknown(shape) }
        var result: [Thread] = []
        for (scope, value) in scopes {
            guard let members = value as? [String: Any],
                  let ranges = JSONListCut.members(in: data, path: [threadsField, scope]) else { return .unknown(shape) }
            var sizes: [String: Int64] = [:]
            for range in ranges { if let key = range.key { sizes[key] = Int64(range.range.count) } }
            for (id, item) in members {
                guard let thread = item as? [String: Any], thread["id"] as? String == id,
                      thread["history"] == nil || thread["history"] is [Any] else { return .unknown(shape) }
                let history = thread["history"] as? [[String: Any]] ?? []
                result.append(Thread(
                    id: id, scope: scope,
                    title: (thread["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    createdAt: (thread["create_time"] as? String).flatMap(date),
                    updatedAt: (thread["update_time"] as? String).flatMap(date),
                    project: (thread["ideContextFolderUris"] as? [Any])?.lazy.compactMap(path(of:)).first,
                    traceIDs: history.compactMap { $0["traceId"] as? String },
                    ranAgentMode: !((thread["a2aTaskId"] as? String) ?? "").isEmpty,
                    bytes: sizes[id] ?? 0))
            }
        }
        return .known(result, valueBytes: Int64(data.count))
    }

    /// The thread's messages: `entity` USER is the person, anything else (SYSTEM) is the reply.
    static func transcript(_ database: URL, id: String, limit: Int) -> Transcript {
        guard let data = VSCodeState.value(key, in: database),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scopes = object[threadsField] as? [String: Any] else { return .empty }
        for case let members as [String: Any] in scopes.values {
            guard let thread = members[id] as? [String: Any] else { continue }
            var messages: [TranscriptMessage] = []
            for (index, entry) in (thread["history"] as? [[String: Any]] ?? []).enumerated() {
                guard let text = entry["markdownText"] as? String, !text.isEmpty else { continue }
                if messages.count == limit { return Transcript(messages: messages, isTruncated: true) }
                messages.append(TranscriptMessage(id: "\(index)", role: entry["entity"] as? String == "USER" ? .user : .assistant,
                                                  timestamp: nil, blocks: [.text(text)]))
            }
            return Transcript(messages: messages, isTruncated: false)
        }
        return .empty
    }

    /// `2026-07-09T10:11:12.345Z`.
    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// A folder URI as a string (`file:///…`) or an object with one (`{uri}`, `{external}`).
    private static func path(of value: Any) -> String? {
        let text = value as? String ?? ((value as? [String: Any]).flatMap { ($0["external"] ?? $0["uri"] ?? $0["path"]) as? String })
        guard let text else { return nil }
        if let url = URL(string: text), url.isFileURL { return url.path }
        return text.hasPrefix("/") ? text : nil
    }
}
