import Foundation

/// Sessions of `opencode.db`, read only. Sizes are estimates: the bytes of a session's message,
/// part and event rows, which is what deleting it gives back to the database (not to the disk:
/// SQLite reuses the pages). Titles and paths are shown, never logged.
struct OpenCodeIndex: Sendable {
    struct Row: Sendable {
        let id: String
        let title: String?
        let directory: String?
        let created: Date?
        let updated: Date?
        let parentID: String?
        let isArchived: Bool
        let messageCount: Int
        /// Bytes of its `message` and `part` rows.
        let contentBytes: Int64
        /// Bytes of its rows in the `event` log.
        let eventBytes: Int64
    }

    let rows: [String: Row]

    /// Top-level sessions; subagent sessions belong to their parent.
    var topLevel: [Row] {
        rows.values.filter { row in row.parentID.map { rows[$0] == nil } ?? true }
    }

    /// Every session below `id`, deepest first, so children go before their parents.
    func descendants(of id: String) -> [Row] {
        let children = rows.values.filter { $0.parentID == id }.sorted { $0.id < $1.id }
        return children.flatMap { descendants(of: $0.id) + [$0] }
    }

    static func load(_ layout: OpenCodeLayout) -> OpenCodeIndex {
        guard let reader = SQLiteReader(url: layout.database) else { return OpenCodeIndex(rows: [:]) }
        let sessionColumns = reader.columns(of: "session")
        let archived = sessionColumns.contains("time_archived") ? "s.time_archived" : "NULL"
        let events = reader.columns(of: "event").isSuperset(of: ["aggregate_id", "data"])
            ? "(SELECT coalesce(sum(length(e.data)), 0) FROM event e WHERE e.aggregate_id = s.id)" : "0"
        let sql = """
            SELECT s.id, s.title, s.directory, s.time_created, s.time_updated, s.parent_id, \(archived),
              (SELECT count(*) FROM message m WHERE m.session_id = s.id),
              (SELECT coalesce(sum(length(m.data)), 0) FROM message m WHERE m.session_id = s.id)
                + (SELECT coalesce(sum(length(p.data)), 0) FROM part p WHERE p.session_id = s.id),
              \(events)
            FROM session s
            """
        var rows: [String: Row] = [:]
        for cells in reader.rows(sql) where cells.count == 10 {
            guard let id = cells[0], !id.isEmpty else { continue }
            rows[id] = Row(
                id: id,
                title: clean(cells[1]),
                directory: cells[2].flatMap { $0.hasPrefix("/") ? $0 : nil },
                created: date(cells[3]),
                updated: date(cells[4]),
                parentID: cells[5].flatMap { $0.isEmpty ? nil : $0 },
                isArchived: cells[6] != nil,
                messageCount: cells[7].flatMap { Int($0) } ?? 0,
                contentBytes: cells[8].flatMap { Int64($0) } ?? 0,
                eventBytes: cells[9].flatMap { Int64($0) } ?? 0
            )
        }
        return OpenCodeIndex(rows: rows)
    }

    /// OpenCode stores milliseconds since 1970 (verified); seconds are accepted too.
    static func date(_ text: String?) -> Date? {
        guard let text, let value = Double(text), value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
    }

    private static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return nil }
        return line.count > 120 ? String(line.prefix(119)) + "\u{2026}" : line
    }

    // MARK: Transcript

    /// The first `limit` messages of a session with their text and tool parts, display only.
    static func transcript(_ layout: OpenCodeLayout, id: String, limit: Int) -> Transcript {
        guard let reader = SQLiteReader(url: layout.database) else { return .empty }
        let total = reader.rows("SELECT count(*) FROM message WHERE session_id = ?1", [id]).first?.first.flatMap { $0 }.flatMap { Int($0) } ?? 0
        let sql = """
            SELECT m.id, m.time_created, m.data, p.data
            FROM (SELECT id, time_created, data FROM message WHERE session_id = ?1 ORDER BY time_created, id LIMIT \(max(0, limit))) m
            LEFT JOIN part p ON p.message_id = m.id
            ORDER BY m.time_created, m.id, p.id
            """
        var order: [String] = []
        var roles: [String: TranscriptMessage.Role] = [:]
        var times: [String: Date] = [:]
        var blocks: [String: [TranscriptMessage.Block]] = [:]
        for cells in reader.rows(sql, [id]) where cells.count == 4 {
            guard let messageID = cells[0] else { continue }
            if roles[messageID] == nil {
                let message = json(cells[2])
                guard let role = (message?["role"] as? String).flatMap(role) else { continue }
                order.append(messageID)
                roles[messageID] = role
                times[messageID] = date(cells[1])
            }
            if let block = json(cells[3]).flatMap(block) { blocks[messageID, default: []].append(block) }
        }
        let messages = order.compactMap { messageID -> TranscriptMessage? in
            guard let role = roles[messageID], let content = blocks[messageID], !content.isEmpty else { return nil }
            return TranscriptMessage(id: messageID, role: role, timestamp: times[messageID], blocks: content)
        }
        return Transcript(messages: messages, isTruncated: total > limit)
    }

    private static func json(_ text: String?) -> [String: Any]? {
        guard let data = text?.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func role(_ text: String) -> TranscriptMessage.Role? {
        switch text {
        case "user": .user
        case "assistant": .assistant
        default: nil
        }
    }

    /// `{type: text, text}` and `{type: tool, tool}` parts; reasoning and step markers are left out.
    private static func block(_ part: [String: Any]) -> TranscriptMessage.Block? {
        switch part["type"] as? String {
        case "text":
            guard let text = (part["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return .text(text)
        case "tool":
            return .toolCall((part["tool"] as? String) ?? "Tool")
        default:
            return nil
        }
    }
}
