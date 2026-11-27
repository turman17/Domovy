import Foundation

/// Reads a Claude Code transcript for display: user and assistant messages, with tool calls
/// reduced to one-line summaries. Reads a bounded prefix of the file and stops after
/// `maxMessages`. Content is returned to the caller and never logged (safety rule 7).
public struct TranscriptReader: Sendable {
    public let maxMessages: Int
    public let maxBytes: Int

    public init(maxMessages: Int = 200, maxBytes: Int = 4 * 1024 * 1024) {
        self.maxMessages = maxMessages
        self.maxBytes = maxBytes
    }

    public func read(_ url: URL, masking findings: [SecretFinding] = []) throws -> Transcript {
        let mask = TranscriptMask(findings: findings, file: url)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw AdapterError.unreadable(url, reason: error.localizedDescription)
        }
        defer { try? handle.close() }
        // Read one byte past the budget so we know whether the file continues.
        let data = (try? handle.read(upToCount: maxBytes + 1)) ?? Data()
        var truncated = data.count > maxBytes
        let budget = data.prefix(maxBytes)

        var messages: [TranscriptMessage] = []
        var lines = budget.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        // A cut-off final line is not a complete record.
        if truncated, budget.last != UInt8(ascii: "\n") { lines.removeLast() }
        var cwd: String?
        var hidden = 0
        for (index, raw) in lines.enumerated() {
            if messages.count >= maxMessages {
                truncated = true
                break
            }
            guard let line = mask.apply(Data(raw), at: Int64(raw.startIndex - data.startIndex)) else {
                hidden += 1
                continue
            }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if cwd == nil, let dir = object["cwd"] as? String, !dir.isEmpty { cwd = dir }
            guard let message = Self.message(from: object, lineIndex: index, cwd: cwd) else { continue }
            messages.append(message)
        }
        return Transcript(messages: messages, isTruncated: truncated, hiddenLineCount: hidden)
    }

    /// The newest `limit` messages before `cursor`, read from the end of the file.
    public static func readPage(_ url: URL, limit: Int, before cursor: TranscriptCursor?, masking findings: [SecretFinding] = []) throws -> Transcript {
        try TranscriptTail.page(of: url, limit: limit, before: cursor, masking: findings) { lines in
            lines.compactMap { line in
                guard let object = try? JSONSerialization.jsonObject(with: line.data) as? [String: Any] else { return nil }
                let cwd = (object["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return message(from: object, lineIndex: Int(line.offset), cwd: cwd).map { (line.offset, $0) }
            }
        }
    }

    // MARK: Records

    private static func message(from object: [String: Any], lineIndex: Int, cwd: String?) -> TranscriptMessage? {
        guard let type = object["type"] as? String, let role = TranscriptMessage.Role(rawValue: type) else { return nil }
        if object["isMeta"] as? Bool == true { return nil }
        guard let message = object["message"] as? [String: Any] else { return nil }

        var blocks: [TranscriptMessage.Block] = []
        if let text = message["content"] as? String {
            if let cleaned = cleanText(text) { blocks.append(.text(cleaned)) }
        } else if let parts = message["content"] as? [[String: Any]] {
            for part in parts {
                switch part["type"] as? String {
                case "text":
                    if let text = part["text"] as? String, let cleaned = cleanText(text) { blocks.append(.text(cleaned)) }
                case "tool_use":
                    let name = part["name"] as? String ?? "Tool"
                    let input = part["input"] as? [String: Any] ?? [:]
                    blocks.append(.toolCall(toolSummary(name: name, input: input, cwd: cwd)))
                default:
                    break // tool_result, thinking, images: not shown
                }
            }
        }
        guard !blocks.isEmpty else { return nil }

        let id = object["uuid"] as? String ?? "line-\(lineIndex)"
        let timestamp = (object["timestamp"] as? String).flatMap(parseTimestamp)
        return TranscriptMessage(id: id, role: role, timestamp: timestamp, blocks: blocks)
    }

    /// Trims and drops the machine-generated records Claude Code stores as user text.
    private static func cleanText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for prefix in ["<command-", "<local-command", "<bash-", "<system-reminder"] where trimmed.hasPrefix(prefix) {
            return nil
        }
        return trimmed
    }

    // MARK: Tool summaries

    static let maxSummaryLength = 80

    /// "Edit src/App.swift", "Bash Run the tests", "Grep TODO". Paths are shown relative to the
    /// session's working directory.
    static func toolSummary(name: String, input: [String: Any], cwd: String?) -> String {
        func string(_ key: String) -> String? {
            guard let value = input[key] as? String else { return nil }
            let firstLine = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value
            let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        func path(_ key: String) -> String? {
            guard let value = string(key) else { return nil }
            if let cwd, value.hasPrefix(cwd + "/") { return String(value.dropFirst(cwd.count + 1)) }
            return value
        }

        let detail: String?
        switch name {
        case "Edit", "Write", "Read", "MultiEdit":
            detail = path("file_path")
        case "NotebookEdit":
            detail = path("notebook_path")
        case "Bash":
            detail = string("description") ?? string("command")
        case "Grep", "Glob":
            detail = string("pattern")
        case "Agent", "Task":
            detail = string("description") ?? string("subagent_type")
        case "WebFetch":
            detail = string("url")
        case "WebSearch":
            detail = string("query")
        case "Skill":
            detail = string("skill")
        default:
            detail = string("description")
        }
        let summary = detail.map { "\(name) \($0)" } ?? name
        guard summary.count > maxSummaryLength else { return summary }
        return String(summary.prefix(maxSummaryLength - 1)) + "\u{2026}"
    }
}

/// Claude Code writes `2026-11-01T10:00:00.000Z`; older records omit the fraction.
private func parseTimestamp(_ text: String) -> Date? {
    (try? Date(text, strategy: .iso8601.year().month().day().dateTimeSeparator(.standard).time(includingFractionalSeconds: true)))
        ?? (try? Date(text, strategy: .iso8601))
}
