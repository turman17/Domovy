import Foundation

/// VS Code's chat list and chat files, read-only.
///
/// The index (`chat.ChatSessionStore.index`) is `{version: 1, entries: {<sessionId>: {sessionId,
/// title, lastMessageDate (ms), timing, initialLocation, isEmpty, …}}}`
/// (chatSessionStore.ts lines 780-836, `IChatSessionEntryMetadata` / `IChatSessionIndexData`;
/// verified on VS Code 1.138). VS Code tolerates both an entry without a file and a file
/// without an entry, so Domovy lists both.
///
/// The files are written from VS Code's source, not from a real install (none on the
/// development Mac had chats): `<id>.json` is `ISerializableChatData` version 3 (chatModel.ts
/// lines 2370-2392: `sessionId`, `creationDate`, `customTitle`, `requests`), and `<id>.jsonl` is
/// an operation log (objectMutationLog.ts lines 196-213): one JSON object per line, the first
/// `{kind: 0, v: <whole state>}`, then `{kind: 1, k: <path>, v}` (set), `{kind: 2, k, v?, i?}`
/// (push or truncate) and `{kind: 3, k}` (delete). The parser only reads what it recognises.
enum VSCodeChatIndex {
    struct Entry: Sendable, Hashable {
        let id: String
        let title: String?
        let lastMessage: Date?
        let isEmpty: Bool
    }

    enum State: Sendable {
        /// No index value: nothing listed.
        case absent
        case known([String: Entry], bytes: [String: Int64])
        case unknown
    }

    static func load(_ database: URL) -> State {
        guard let data = VSCodeState.value(VSCodeLayout.indexKey, in: database) else { return .absent }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] as? Int == 1, let entries = object["entries"] as? [String: Any],
              let members = JSONListCut.members(in: data, field: "entries") else { return .unknown }
        var result: [String: Entry] = [:]
        var bytes: [String: Int64] = [:]
        for (key, value) in entries {
            guard let entry = value as? [String: Any] else { return .unknown }
            let ms = (entry["lastMessageDate"] as? NSNumber)?.doubleValue
            result[key] = Entry(id: key, title: (entry["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                lastMessage: ms.map { Date(timeIntervalSince1970: $0 / 1000) },
                                isEmpty: entry["isEmpty"] as? Bool ?? false)
        }
        for member in members {
            if let key = member.key { bytes[key] = Int64(member.range.count) }
        }
        return .known(result, bytes: bytes)
    }

    // MARK: Session files

    /// `<id>.json` and `<id>.jsonl` in a store's folder, by session id.
    static func files(in folder: URL) -> [String: [URL]] {
        var result: [String: [URL]] = [:]
        for file in FileSystem.children(of: folder) {
            let name = file.lastPathComponent
            for suffix in [".jsonl", ".json"] where name.hasSuffix(suffix) {
                let id = String(name.dropLast(suffix.count))
                if SafeID.isSafe(id) { result[id, default: []].append(file) }
                break
            }
        }
        return result.mapValues { $0.sorted { $0.lastPathComponent > $1.lastPathComponent } } // .jsonl first
    }

    /// The chat as `ISerializableChatData`: the `.json` file, or the `.jsonl` log replayed.
    static func chat(at file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        if file.pathExtension == "jsonl" { return replay(data) as? [String: Any] }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Replays an operation log. Lines Domovy does not recognise are skipped.
    static func replay(_ data: Data) -> Any? {
        var state: Any?
        for line in JSONLines.split(data).lines where !line.isEmpty {
            guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let kind = (entry["kind"] as? NSNumber)?.intValue else { continue }
            let path = entry["k"] as? [Any] ?? []
            switch kind {
            case 0:
                state = entry["v"]
            case 1:
                let value = entry["v"]
                state = apply(state, path[...]) { _ in value }
            case 2:
                let items = entry["v"] as? [Any]
                let length = (entry["i"] as? NSNumber)?.intValue
                state = apply(state, path[...]) { existing in
                    var array = existing as? [Any] ?? []
                    if let length { array = Array(array.prefix(length)) }
                    return array + (items ?? [])
                }
            case 3:
                state = apply(state, path[...]) { _ in nil }
            default:
                continue
            }
        }
        return state
    }

    /// `root` with the value at `path` replaced by `change(old)`; `nil` from `change` removes it.
    private static func apply(_ root: Any?, _ path: ArraySlice<Any>, _ change: (Any?) -> Any?) -> Any? {
        guard let first = path.first else { return change(root) }
        let rest = path.dropFirst()
        if let key = first as? String {
            var object = root as? [String: Any] ?? [:]
            object[key] = apply(object[key], rest, change)
            return object
        }
        guard let index = (first as? NSNumber)?.intValue, index >= 0, var array = root as? [Any] else { return root }
        if index < array.count {
            if let value = apply(array[index], rest, change) { array[index] = value } else { array.remove(at: index) }
        } else if index == array.count, let value = apply(nil, rest, change) {
            array.append(value)
        }
        return array
    }

    /// The custom title, or the first request's text.
    static func title(of chat: [String: Any]) -> String? {
        if let custom = chat["customTitle"] as? String, !custom.isEmpty { return custom }
        if let computed = chat["computedTitle"] as? String, !computed.isEmpty { return computed }
        guard let first = (chat["requests"] as? [[String: Any]])?.first else { return nil }
        return Session.cleanTitle(messageText(first["message"]))
    }

    /// `message` is a string (old format) or `{text, parts}`.
    static func messageText(_ message: Any?) -> String? {
        if let text = message as? String { return text }
        return (message as? [String: Any])?["text"] as? String
    }

    /// Requests in order: the user's message, then the response parts with text (`IMarkdownString`
    /// `{value}`, or `{kind: "markdownContent", content: {value}}`) and tool calls.
    static func transcript(of chat: [String: Any], limit: Int) -> Transcript {
        var messages: [TranscriptMessage] = []
        let requests = chat["requests"] as? [[String: Any]] ?? []
        for (index, request) in requests.enumerated() {
            let when = (request["timestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            if let text = messageText(request["message"]), !text.isEmpty {
                if messages.count == limit { return Transcript(messages: messages, isTruncated: true) }
                messages.append(TranscriptMessage(id: "\(index)-q", role: .user, timestamp: when, blocks: [.text(text)]))
            }
            var blocks: [TranscriptMessage.Block] = []
            var text = ""
            for part in request["response"] as? [[String: Any]] ?? [] {
                let kind = part["kind"] as? String
                if let value = part["value"] as? String, kind == nil || kind == "markdownContent" {
                    text += value
                } else if let content = part["content"] as? [String: Any], let value = content["value"] as? String {
                    text += value
                } else if kind == "toolInvocationSerialized" || kind == "toolInvocation" {
                    if !text.isEmpty { blocks.append(.text(text)); text = "" }
                    let label = (part["invocationMessage"] as? [String: Any])?["value"] as? String ?? part["invocationMessage"] as? String
                    blocks.append(.toolCall(label ?? (part["toolId"] as? String) ?? "Tool call"))
                }
            }
            if !text.isEmpty { blocks.append(.text(text)) }
            guard !blocks.isEmpty else { continue }
            if messages.count == limit { return Transcript(messages: messages, isTruncated: true) }
            messages.append(TranscriptMessage(id: "\(index)-a", role: .assistant, timestamp: nil, blocks: blocks))
        }
        return Transcript(messages: messages, isTruncated: false)
    }
}
