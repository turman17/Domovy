import Foundation

/// Cursor's editor chats, read from `state.vscdb` (read-only). Verified on a real install, by
/// key shape and JSON field names only: a chat is `composerData:<chat id>` (JSON with
/// `composerId`, `createdAt` in ms, `fullConversationHeadersOnly: [{bubbleId, type}]`,
/// `subComposerIds`, `name` on newer versions) plus rows keyed `<prefix>:<chat id>:<item id>`.
/// Messages are `bubbleId:` rows (JSON `type` 1 user, 2 assistant, `text`, ISO `createdAt`).
/// Content-addressed blobs (`composer.content.<hash>`, most `agentKv:` rows) are shared and
/// never counted as one chat's.
struct CursorIndex: Sendable {
    struct Chat: Sendable {
        let id: String
        let title: String?
        let workspace: String?
        let createdAt: Date?
        let updatedAt: Date?
        /// Rows of this chat across every per-chat prefix, its `composerData` row included.
        let rows: Int
        /// Bytes of those rows' values.
        let bytes: Int64
        let messages: Int
        let subChats: Int
        let isListed: Bool
    }

    /// Prefixes of keys `<prefix>:<chat id>:<item id>`. The first five are verified to carry the
    /// chat's id; `agentKv:` rows count only when shaped the same way (assumed).
    static let perChatPrefixes: [(prefix: String, note: String)] = [
        ("bubbleId", "Messages"),
        ("checkpointId", "Checkpoints"),
        ("messageRequestContext", "Request context"),
        ("codeBlockDiff", "Code block diffs"),
        ("codeBlockPartialInlineDiffFates", "Inline diff state"),
        ("agentKv", "Agent state keyed by this chat"),
    ]
    static let dataPrefix = "composerData:"

    /// Chats worth listing: named, with messages, or on Cursor's chat list.
    let chats: [String: Chat]
    /// `composerData` rows with nothing in them (a new tab never used).
    let emptyDrafts: Int
    let headers: CursorHeaders.State
    /// `agentKv:` rows that name no chat; Cursor's own GC removes the unused ones.
    let sharedAgentKvRows: Int

    static func load(_ layout: CursorLayout) -> CursorIndex? {
        guard let reader = SQLiteReader(url: layout.database), case .ready = layout.databaseState() else { return nil }
        let size = sizeExpression(reader)
        let headers = CursorHeaders.load(reader)
        var listed: [String: CursorHeaders.Entry] = [:]
        if case .known(_, let entries) = headers { listed = entries }

        var perChat: [String: (rows: Int, bytes: Int64)] = [:]
        var agentKvTotal = 0
        for (prefix, _) in perChatPrefixes {
            let start = prefix.count + 2
            let sql = """
                SELECT substr(key, \(start), instr(substr(key, \(start)), ':') - 1), count(*), coalesce(sum(\(size)), 0)
                FROM cursorDiskKV WHERE key >= ?1 AND key < ?2 AND instr(substr(key, \(start)), ':') > 0 GROUP BY 1
                """
            for cells in reader.rows(sql, keyRange(prefix + ":")) where cells.count == 3 {
                guard let id = cells[0] ?? nil else { continue }
                let rows = Int(cells[1] ?? "") ?? 0
                if prefix == "agentKv" { agentKvTotal += rows }
                let current = perChat[id] ?? (0, 0)
                perChat[id] = (current.rows + rows, current.bytes + (Int64(cells[2] ?? "") ?? 0))
            }
        }
        // `agentKv:` keys whose second part is no chat are shared blobs.
        var agentKvOfChats = 0

        let text = "CASE typeof(value) WHEN 'blob' THEN CAST(value AS TEXT) ELSE value END"
        let sql = """
            WITH c AS (SELECT substr(key, \(dataPrefix.count + 1)) AS id, \(size) AS size, \(text) AS raw
                       FROM cursorDiskKV WHERE key >= ?1 AND key < ?2),
                 j AS (SELECT id, size, CASE WHEN json_valid(raw) THEN raw END AS v FROM c)
            SELECT id, size, json_extract(v, '$.name'), json_extract(v, '$.createdAt'), json_extract(v, '$.lastUpdatedAt'),
                   json_array_length(v, '$.fullConversationHeadersOnly'),
                   (SELECT json_extract(h.value, '$.bubbleId') FROM json_each(v, '$.fullConversationHeadersOnly') h
                    WHERE json_extract(h.value, '$.type') = 1 LIMIT 1),
                   json_extract(v, '$.fullConversationHeadersOnly[#-1].bubbleId'),
                   json_array_length(v, '$.subComposerIds')
            FROM j
            """
        var chats: [String: Chat] = [:]
        var empty = 0
        for cells in reader.rows(sql, keyRange(dataPrefix)) where cells.count == 9 {
            guard let id = cells[0] ?? nil, !id.isEmpty else { continue }
            let own = perChat[id] ?? (0, 0)
            let header = listed[id]
            let name = (cells[2] ?? nil).flatMap { $0.isEmpty ? nil : $0 } ?? header?.name
            let messages = Int(cells[5] ?? "") ?? 0
            let bubbles = reader.rows("SELECT count(*) FROM cursorDiskKV WHERE key >= ?1 AND key < ?2 LIMIT 1", keyRange("bubbleId:\(id):"))
                .first?.first.flatMap { $0 }.flatMap { Int($0) } ?? 0
            guard name != nil || bubbles > 0 || header != nil else {
                empty += 1
                continue
            }
            agentKvOfChats += reader.rows("SELECT count(*) FROM cursorDiskKV WHERE key >= ?1 AND key < ?2", keyRange("agentKv:\(id):"))
                .first?.first.flatMap { $0 }.flatMap { Int($0) } ?? 0
            let firstPrompt = (cells[6] ?? nil).flatMap { bubbleField(reader, chat: id, bubble: $0, "text") }.flatMap(titleLine)
            let lastBubble = (cells[7] ?? nil).flatMap { bubbleField(reader, chat: id, bubble: $0, "createdAt") }.flatMap(isoDate)
            let created = (cells[3] ?? nil).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) } ?? header?.createdAt
            let updated = (cells[4] ?? nil).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) } ?? header?.updatedAt
            chats[id] = Chat(
                id: id,
                title: name ?? firstPrompt,
                workspace: header?.workspace,
                createdAt: created,
                updatedAt: [updated, lastBubble].compactMap { $0 }.max(),
                rows: own.rows + 1,
                bytes: own.bytes + (Int64(cells[1] ?? "") ?? 0),
                messages: max(messages, bubbles),
                subChats: Int(cells[8] ?? "") ?? 0,
                isListed: header != nil
            )
        }
        return CursorIndex(chats: chats, emptyDrafts: empty, headers: headers, sharedAgentKvRows: max(0, agentKvTotal - agentKvOfChats))
    }

    /// Another chat whose id starts with `<id>:`: its rows would match this chat's prefixes.
    static func hasLongerIDs(of id: String, in layout: CursorLayout) -> Bool {
        guard let reader = SQLiteReader(url: layout.database) else { return true }
        let found = reader.rows("SELECT count(*) FROM cursorDiskKV WHERE key >= ?1 AND key < ?2", keyRange(dataPrefix + id + ":")).first ?? []
        return (Int((found.first ?? nil) ?? "") ?? 1) > 0
    }

    /// Every row a delete of `id` removes, counted now. `composerData:<id>` first.
    static func rows(of id: String, in layout: CursorLayout) -> [DatabaseEdit.Rows] {
        guard let reader = SQLiteReader(url: layout.database) else { return [] }
        let size = sizeExpression(reader)
        func measure(_ sql: String, _ arguments: [String]) -> (Int, Int64) {
            let cells = reader.rows(sql, arguments).first ?? []
            return (Int((cells.first ?? nil) ?? "") ?? 0, Int64((cells.last ?? nil) ?? "") ?? 0)
        }
        var result: [DatabaseEdit.Rows] = []
        let key = dataPrefix + id
        let data = measure("SELECT count(*), coalesce(sum(\(size)), 0) FROM cursorDiskKV WHERE key = ?1", [key])
        if data.0 > 0 {
            result.append(.init(table: "cursorDiskKV", key: key, isPrefix: false, count: data.0, bytes: data.1, note: "The chat itself"))
        }
        for (prefix, note) in perChatPrefixes {
            let start = "\(prefix):\(id):"
            let found = measure("SELECT count(*), coalesce(sum(\(size)), 0) FROM cursorDiskKV WHERE key >= ?1 AND key < ?2", keyRange(start))
            guard found.0 > 0 else { continue }
            result.append(.init(table: "cursorDiskKV", key: start, isPrefix: true, count: found.0, bytes: found.1, note: note))
        }
        return result
    }

    /// Pre-3.0 workspace databases that still list `id` in `composer.composerData`. Domovy does
    /// not edit those, so a delete then refuses.
    static func workspaceListings(of id: String, in layout: CursorLayout) -> [URL] {
        FileSystem.children(of: layout.workspaceStorage).compactMap { folder in
            let database = folder.appendingPathComponent("state.vscdb")
            guard let reader = SQLiteReader(url: database) else { return nil }
            let found = reader.rows("SELECT count(*) FROM ItemTable WHERE key = ?1 AND instr(CAST(value AS TEXT), ?2) > 0",
                                    [CursorLayout.workspaceListKey, id]).first?.first.flatMap { $0 }.flatMap { Int($0) } ?? 0
            return found > 0 ? database : nil
        }
    }

    // MARK: Transcript

    /// The first `limit` messages, for display only, with possible secrets masked.
    static func transcript(_ layout: CursorLayout, id: String, limit: Int) -> Transcript {
        guard let reader = SQLiteReader(url: layout.database) else { return .empty }
        let ordered = """
            SELECT json_extract(h.value, '$.bubbleId')
            FROM (SELECT CASE WHEN json_valid(x) THEN x END AS v
                  FROM (SELECT CASE typeof(value) WHEN 'blob' THEN CAST(value AS TEXT) ELSE value END AS x
                        FROM cursorDiskKV WHERE key = ?1)) AS c, json_each(c.v, '$.fullConversationHeadersOnly') AS h
            """
        var bubbles = reader.rows(ordered, [dataPrefix + id]).compactMap { $0.first ?? nil }
        if bubbles.isEmpty {
            // No header list: the rows in the order Cursor wrote them.
            let start = "bubbleId:\(id):"
            bubbles = reader.rows("SELECT substr(key, \(start.count + 1)) FROM cursorDiskKV WHERE key >= ?1 AND key < ?2 ORDER BY rowid LIMIT \(limit + 1)",
                                  keyRange(start)).compactMap { $0.first ?? nil }
        }
        let masker = TranscriptMask.TextMasker()
        var messages: [TranscriptMessage] = []
        for bubble in bubbles.prefix(limit) {
            let cells = reader.rows("""
                SELECT json_extract(v, '$.type'), json_extract(v, '$.text'), json_extract(v, '$.createdAt')
                FROM (SELECT CASE WHEN json_valid(x) THEN x END AS v
                      FROM (SELECT CASE typeof(value) WHEN 'blob' THEN CAST(value AS TEXT) ELSE value END AS x
                            FROM cursorDiskKV WHERE key = ?1))
                """, ["bubbleId:\(id):\(bubble)"]).first ?? []
            guard cells.count == 3, let role = (cells[0] ?? nil).flatMap(role),
                  let text = (cells[1] ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            messages.append(TranscriptMessage(id: bubble, role: role, timestamp: (cells[2] ?? nil).flatMap(isoDate),
                                              blocks: [.text(masker.mask(String(text.prefix(maxMessageCharacters))))]))
        }
        return Transcript(messages: messages, isTruncated: bubbles.count > limit)
    }

    static let maxMessageCharacters = 20_000

    // MARK: Helpers

    /// Byte length of `value`: `octet_length` reads only the record header, so a 30 GB
    /// database is measured without reading its contents. Older SQLite falls back to a cast.
    static func sizeExpression(_ reader: SQLiteReader) -> String {
        reader.rows("SELECT octet_length('a')").isEmpty ? "length(CAST(value AS BLOB))" : "octet_length(value)"
    }

    /// Bounds of every key starting with `prefix`, as two query arguments.
    static func keyRange(_ prefix: String) -> [String] {
        [prefix, SQLiteWriter.upperBound(of: prefix) ?? prefix]
    }

    private static func bubbleField(_ reader: SQLiteReader, chat: String, bubble: String, _ field: String) -> String? {
        let cells = reader.rows("""
            SELECT json_extract(v, '$.\(field)')
            FROM (SELECT CASE WHEN json_valid(x) THEN x END AS v
                  FROM (SELECT CASE typeof(value) WHEN 'blob' THEN CAST(value AS TEXT) ELSE value END AS x
                        FROM cursorDiskKV WHERE key = ?1))
            """, ["bubbleId:\(chat):\(bubble)"])
        return cells.first?.first ?? nil
    }

    private static func role(_ type: String) -> TranscriptMessage.Role? {
        switch type {
        case "1": .user
        case "2": .assistant
        default: nil
        }
    }

    /// The first non-empty line of a prompt, shortened, with possible secrets masked.
    private static func titleLine(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return line.map { TranscriptMask.TextMasker().mask(String($0.prefix(200))) }
    }

    private static func isoDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
