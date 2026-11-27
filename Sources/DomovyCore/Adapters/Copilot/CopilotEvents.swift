import Foundation

/// Reads Copilot CLI's `events.jsonl` (assumed shape): one event per line,
/// `{type, data, id, timestamp}`, with `session.start` (`data.context.cwd` or `data.cwd`),
/// `user.message` and `assistant.message` (`data.content`). A `workspace.yaml` next to it may
/// carry `summary:` and `cwd:`. Reads a bounded prefix; content is never logged.
enum CopilotEvents {
    struct Header: Sendable {
        var title: String?
        var cwd: String?
    }

    static let maxHeaderBytes = 256 * 1024
    static let maxTitleLength = 120

    static func readHeader(of folder: URL) -> Header {
        var header = Header()
        let workspace = workspaceFields(folder.appendingPathComponent("workspace.yaml"))
        header.title = workspace["summary"].flatMap(clean)
        header.cwd = workspace["cwd"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        guard header.title == nil || header.cwd == nil else { return header }
        for event in events(in: folder.appendingPathComponent("events.jsonl"), maxBytes: maxHeaderBytes) {
            let type = event["type"] as? String
            let data = event["data"] as? [String: Any] ?? [:]
            if header.cwd == nil, type == "session.start" {
                let context = data["context"] as? [String: Any]
                header.cwd = ((context?["cwd"] ?? data["cwd"]) as? String).flatMap { $0.hasPrefix("/") ? $0 : nil }
            }
            if header.title == nil, type == "user.message", let text = data["content"] as? String {
                header.title = clean(text)
            }
            if header.title != nil, header.cwd != nil { break }
        }
        return header
    }

    /// Up to `maxMessages` user and assistant messages, after masking scan findings line by line.
    static func readTranscript(of file: URL, maxMessages: Int, maxBytes: Int = 4 * 1024 * 1024, masking findings: [SecretFinding]) throws -> Transcript {
        let mask = TranscriptMask(findings: findings, file: file)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: file)
        } catch {
            throw AdapterError.unreadable(file, reason: error.localizedDescription)
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes + 1)) ?? Data()
        var truncated = data.count > maxBytes
        let budget = data.prefix(maxBytes)
        var lines = budget.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if truncated, budget.last != UInt8(ascii: "\n"), !lines.isEmpty { lines.removeLast() }
        var messages: [TranscriptMessage] = []
        var hidden = 0
        for raw in lines {
            guard let line = mask.apply(Data(raw), at: Int64(raw.startIndex - data.startIndex)) else {
                hidden += 1
                continue
            }
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = message(from: event, index: messages.count) else { continue }
            if messages.count >= maxMessages {
                truncated = true
                break
            }
            messages.append(message)
        }
        return Transcript(messages: messages, isTruncated: truncated, hiddenLineCount: hidden)
    }

    /// The newest `limit` messages before `cursor`, read from the end of the file.
    static func readPage(of file: URL, limit: Int, before cursor: TranscriptCursor?, masking findings: [SecretFinding]) throws -> Transcript {
        try TranscriptTail.page(of: file, limit: limit, before: cursor, masking: findings) { lines in
            lines.compactMap { line in
                guard let event = try? JSONSerialization.jsonObject(with: line.data) as? [String: Any] else { return nil }
                return message(from: event, index: Int(line.offset)).map { (line.offset, $0) }
            }
        }
    }

    private static func message(from event: [String: Any], index: Int) -> TranscriptMessage? {
        let role: TranscriptMessage.Role
        switch event["type"] as? String {
        case "user.message": role = .user
        case "assistant.message": role = .assistant
        default: return nil
        }
        let data = event["data"] as? [String: Any] ?? [:]
        var blocks: [TranscriptMessage.Block] = []
        if let text = (data["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            blocks.append(.text(text))
        }
        for case let request as [String: Any] in data["toolRequests"] as? [Any] ?? [] {
            blocks.append(.toolCall((request["name"] as? String) ?? "Tool"))
        }
        guard !blocks.isEmpty else { return nil }
        let timestamp = (event["timestamp"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        return TranscriptMessage(id: (event["id"] as? String) ?? "e\(index)", role: role, timestamp: timestamp, blocks: blocks)
    }

    /// JSON objects of the first `maxBytes`; a cut-off last line is skipped.
    private static func events(in file: URL, maxBytes: Int) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes + 1), !data.isEmpty else { return [] }
        let complete = data.count <= maxBytes
        var lines = data.prefix(maxBytes).split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if !complete, !lines.isEmpty { lines.removeLast() }
        return lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }

    /// Top-level `key: value` lines of a small YAML file; nothing nested, nothing else.
    static func workspaceFields(_ url: URL) -> [String: String] {
        guard FileSystem.size(of: url) < 64 * 1024, let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix(" ") && !line.hasPrefix("#") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            if !value.isEmpty { fields[key] = value }
        }
        return fields
    }

    private static func clean(_ text: String) -> String? {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > maxTitleLength ? String(trimmed.prefix(maxTitleLength - 1)) + "\u{2026}" : trimmed
    }
}
