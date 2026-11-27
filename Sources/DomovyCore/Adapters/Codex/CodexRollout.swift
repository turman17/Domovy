import Foundation

/// Reads plain `.jsonl` Codex rollouts for display. Records are `{type, payload}`:
/// `session_meta` (cwd), `response_item` (messages, tool calls), `event_msg` (user_message).
/// Older rollouts have no wrapper; the record itself is then the payload. `.jsonl.zst` files
/// (Codex's own compression of old rollouts) are read through the vendored zstd decoder.
/// Transcripts may hold secrets: reads are bounded and nothing read here is logged.
enum CodexRollout {
    struct Header: Sendable {
        var cwd: String?
        var title: String?
    }

    static let maxHeaderBytes = 512 * 1024
    static let maxTitleLength = 120

    static func readHeader(of url: URL) -> Header {
        guard let data = try? Zstd.prefix(of: url, maxBytes: maxHeaderBytes), !data.isEmpty else { return Header() }

        var header = Header()
        var firstResponsePrompt: String?
        for line in JSONLines.nonEmptyLines(data) {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let (type, payload) = unwrap(record)
            switch type {
            case "session_meta":
                if header.cwd == nil, let cwd = payload["cwd"] as? String, !cwd.isEmpty { header.cwd = cwd }
            case "event_msg":
                if header.title == nil, payload["type"] as? String == "user_message",
                   let message = payload["message"] as? String, let prompt = cleanPrompt(message) {
                    header.title = prompt
                }
            default:
                if firstResponsePrompt == nil, payload["type"] as? String == "message", payload["role"] as? String == "user" {
                    firstResponsePrompt = text(of: payload).flatMap(cleanPrompt)
                }
            }
            if header.title != nil, header.cwd != nil { break }
        }
        if header.title == nil { header.title = firstResponsePrompt }
        return header
    }

    /// User and assistant messages with tool calls as one-line summaries, for the preview pane.
    static func readTranscript(of url: URL, maxMessages: Int, maxBytes: Int = 4 * 1024 * 1024, masking findings: [SecretFinding] = []) throws -> Transcript {
        let data: Data
        do {
            data = try Zstd.prefix(of: url, maxBytes: maxBytes + 1)
        } catch {
            throw AdapterError.unreadable(url, reason: error.localizedDescription)
        }
        var truncated = data.count > maxBytes
        let budget = data.prefix(maxBytes)
        var lines = budget.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if truncated, budget.last != UInt8(ascii: "\n") { lines.removeLast() }

        let mask = TranscriptMask(findings: findings, file: url)
        var hidden = 0
        var masked: [TranscriptTail.Line] = []
        for raw in lines {
            let offset = Int64(raw.startIndex - data.startIndex)
            guard let line = mask.apply(Data(raw), at: offset) else {
                hidden += 1
                continue
            }
            masked.append(TranscriptTail.Line(offset: offset, data: line))
        }
        let parsed = parse(masked)
        if parsed.count > maxMessages { truncated = true }
        let messages = parsed.prefix(maxMessages).map(\.message)
        return Transcript(messages: messages, isTruncated: truncated, hiddenLineCount: hidden)
    }

    /// The newest `limit` messages before `cursor`. A compressed rollout is read up to
    /// `maxCompressedBytes` from its start, as it cannot be read from the end.
    static func readPage(of url: URL, limit: Int, before cursor: TranscriptCursor?, masking findings: [SecretFinding] = [],
                         maxCompressedBytes: Int = 32 * 1024 * 1024) throws -> Transcript {
        guard url.lastPathComponent.hasSuffix(".zst") else {
            return try TranscriptTail.page(of: url, limit: limit, before: cursor, masking: findings, parse: parse)
        }
        var data: Data
        do {
            data = try Zstd.prefix(of: url, maxBytes: maxCompressedBytes + 1)
        } catch {
            throw AdapterError.unreadable(url, reason: error.localizedDescription)
        }
        let cut = data.count > maxCompressedBytes
        if cut, let lastNewline = data.prefix(maxCompressedBytes).lastIndex(of: UInt8(ascii: "\n")) {
            data = data.prefix(through: lastNewline)
        }
        return try TranscriptTail.page(of: url, limit: limit, before: cursor, masking: findings, contents: data, contentsCut: cut, parse: parse)
    }

    /// Masked lines, oldest first, as messages; a tool call joins the assistant message before it.
    private static func parse(_ lines: [TranscriptTail.Line]) -> [TranscriptTail.Parsed] {
        var messages: [TranscriptTail.Parsed] = []
        for line in lines {
            guard let record = try? JSONSerialization.jsonObject(with: line.data) as? [String: Any] else { continue }
            let (type, payload) = unwrap(record)
            guard type == "response_item" || type == nil else { continue }
            let timestamp = (record["timestamp"] as? String).flatMap(parseDate)
            let id = "\(line.offset)"
            switch payload["type"] as? String {
            case "message":
                guard let role = payload["role"] as? String, let text = text(of: payload), !text.isEmpty else { continue }
                if role == "user", !isUserPrompt(text) { continue }
                let mapped: TranscriptMessage.Role
                switch role {
                case "user": mapped = .user
                case "assistant": mapped = .assistant
                default: continue
                }
                messages.append((line.offset, TranscriptMessage(id: id, role: mapped, timestamp: timestamp, blocks: [.text(text)])))
            case "function_call", "custom_tool_call", "local_shell_call":
                let name = (payload["name"] as? String) ?? "shell"
                let block = TranscriptMessage.Block.toolCall(name)
                if let last = messages.last, last.message.role == .assistant {
                    let merged = TranscriptMessage(id: last.message.id, role: .assistant, timestamp: last.message.timestamp, blocks: last.message.blocks + [block])
                    messages[messages.count - 1] = (last.offset, merged)
                } else {
                    messages.append((line.offset, TranscriptMessage(id: id, role: .assistant, timestamp: timestamp, blocks: [block])))
                }
            default:
                continue
            }
        }
        return messages
    }

    // MARK: Helpers

    private static func unwrap(_ record: [String: Any]) -> (type: String?, payload: [String: Any]) {
        if let payload = record["payload"] as? [String: Any] { return (record["type"] as? String, payload) }
        return (nil, record)
    }

    /// Joined text blocks (`input_text`, `output_text`, `text`) of a message payload.
    private static func text(of payload: [String: Any]) -> String? {
        if let string = payload["content"] as? String { return string }
        guard let blocks = payload["content"] as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { $0["text"] as? String }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// Codex injects environment context and AGENTS.md instructions as user messages.
    private static func isUserPrompt(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix("<") && !trimmed.hasPrefix("# AGENTS.md")
    }

    static func cleanPrompt(_ text: String) -> String? {
        guard isUserPrompt(text) else { return nil }
        return cleanTitle(text)
    }

    /// First line, trimmed, at most `maxTitleLength` characters.
    static func cleanTitle(_ text: String) -> String? {
        let firstLine = text.split(maxSplits: 1, whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count > maxTitleLength { return String(trimmed.prefix(maxTitleLength - 1)) + "\u{2026}" }
        return trimmed
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
