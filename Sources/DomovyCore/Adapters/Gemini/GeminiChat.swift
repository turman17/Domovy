import Foundation

/// Reads Gemini CLI chat files (verified on 0.43.0): JSON lines whose first record is
/// `{sessionId, projectHash, startTime, lastUpdated, kind}`, followed by messages
/// `{id, timestamp, type: user|gemini|info, content, toolCalls?}` and `{"$set": {...}}`
/// updates that replace the message list or set a `summary`. Older versions wrote one JSON
/// object with a `messages` array. Reads a bounded prefix; content is never logged.
enum GeminiChat {
    struct Header: Sendable {
        var sessionID: String?
        /// `main`, or `subagent` for a chat an agent started.
        var kind: String?
        var title: String?
        /// A user or model message was seen. Gemini CLI lists (and keeps) only such chats.
        var hasMessages = false
    }

    static let maxHeaderBytes = 256 * 1024
    static let maxTitleLength = 120

    static func readHeader(of url: URL) -> Header {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Header() }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxHeaderBytes + 1), !data.isEmpty else { return Header() }
        let complete = data.count <= maxHeaderBytes
        var header = Header()
        var summary: String?
        var firstPrompt: String?
        for object in records(in: data.prefix(maxHeaderBytes), complete: complete) {
            if header.sessionID == nil, let id = object["sessionId"] as? String, !id.isEmpty {
                header.sessionID = id
                header.kind = object["kind"] as? String
            }
            let update = object["$set"] as? [String: Any]
            if let text = (update?["summary"] ?? object["summary"]) as? String { summary = clean(text) ?? summary }
            let messages = (update?["messages"] ?? object["messages"]) as? [[String: Any]] ?? (object["type"] != nil ? [object] : [])
            for message in messages {
                guard let type = message["type"] as? String, type == "user" || type == "gemini" else { continue }
                header.hasMessages = true
                if firstPrompt == nil, type == "user", let text = text(of: message["content"]) { firstPrompt = clean(text) }
            }
        }
        // A chat larger than the budget surely has messages, even if the first ones are long.
        if !complete { header.hasMessages = true }
        header.title = summary ?? firstPrompt
        return header
    }

    /// Up to `maxMessages` user and model messages, after masking scan findings line by line.
    static func readTranscript(of url: URL, maxMessages: Int, maxBytes: Int = 4 * 1024 * 1024, masking findings: [SecretFinding]) throws -> Transcript {
        let mask = TranscriptMask(findings: findings, file: url)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw AdapterError.unreadable(url, reason: error.localizedDescription)
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes + 1)) ?? Data()
        var truncated = data.count > maxBytes
        let budget = data.prefix(maxBytes)

        // Later records win: a `$set` replaces the list, a message line adds or updates one.
        var order: [String] = []
        var byID: [String: [String: Any]] = [:]
        var hidden = 0
        var lines = budget.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if truncated, budget.last != UInt8(ascii: "\n") { lines.removeLast() }
        for raw in lines {
            guard let line = mask.apply(Data(raw), at: Int64(raw.startIndex - data.startIndex)) else {
                hidden += 1
                continue
            }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            let update = object["$set"] as? [String: Any]
            if let list = (update?["messages"] ?? object["messages"]) as? [[String: Any]] {
                order = []
                byID = [:]
                for (index, message) in list.enumerated() {
                    let id = message["id"] as? String ?? "m\(index)"
                    if byID[id] == nil { order.append(id) }
                    byID[id] = message
                }
            } else if object["type"] is String, update == nil {
                let id = object["id"] as? String ?? "line\(order.count)"
                if byID[id] == nil { order.append(id) }
                byID[id] = object
            }
        }

        var messages: [TranscriptMessage] = []
        for id in order {
            guard let object = byID[id], let message = message(from: object, id: id) else { continue }
            if messages.count >= maxMessages {
                truncated = true
                break
            }
            messages.append(message)
        }
        return Transcript(messages: messages, isTruncated: truncated, hiddenLineCount: hidden)
    }

    // MARK: Records

    /// JSON objects of each line; a cut-off last line is skipped. A whole-JSON chat (older
    /// versions) is one object.
    private static func records(in data: Data, complete: Bool) -> [[String: Any]] {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if !complete, data.last != UInt8(ascii: "\n"), !lines.isEmpty { lines.removeLast() }
        let objects = lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        if objects.isEmpty, complete, let whole = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return [whole]
        }
        return objects
    }

    private static func message(from object: [String: Any], id: String) -> TranscriptMessage? {
        let role: TranscriptMessage.Role
        switch object["type"] as? String {
        case "user": role = .user
        case "gemini": role = .assistant
        default: return nil // info, warning, error: Gemini CLI's own notices
        }
        var blocks: [TranscriptMessage.Block] = []
        if let text = text(of: object["content"])?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            blocks.append(.text(text))
        }
        for case let call as [String: Any] in object["toolCalls"] as? [Any] ?? [] {
            let name = (call["displayName"] as? String) ?? (call["name"] as? String) ?? "Tool"
            let detail = (call["description"] as? String).flatMap { $0.split(whereSeparator: \.isNewline).first.map(String.init) }
            let summary = detail.map { "\(name) \($0)" } ?? name
            blocks.append(.toolCall(summary.count > 80 ? String(summary.prefix(79)) + "\u{2026}" : summary))
        }
        guard !blocks.isEmpty else { return nil }
        let timestamp = (object["timestamp"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
            ?? (object["timestamp"] as? String).flatMap(parseFractional)
        return TranscriptMessage(id: id, role: role, timestamp: timestamp, blocks: blocks)
    }

    /// `content` is a string or a list of `{text}` parts.
    static func text(of content: Any?) -> String? {
        if let string = content as? String { return string }
        guard let parts = content as? [[String: Any]] else { return nil }
        let texts = parts.compactMap { $0["text"] as? String }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private static func clean(_ text: String) -> String? {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > maxTitleLength ? String(trimmed.prefix(maxTitleLength - 1)) + "\u{2026}" : trimmed
    }

    private static func parseFractional(_ text: String) -> Date? {
        try? Date(text, strategy: .iso8601.year().month().day().dateTimeSeparator(.standard).time(includingFractionalSeconds: true))
    }
}
