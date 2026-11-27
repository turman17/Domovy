import Foundation

/// What Zed's two databases say about its threads, read once per scan through read-only
/// connections. Titles come from the `summary` and `title` columns; the compressed `data` is
/// only measured, never read here.
struct ZedIndex: Sendable {
    /// One `sidebar_threads` row.
    struct SidebarRow: Sendable, Hashable {
        /// `thread_id`, 16 bytes as lowercase hex.
        let threadHex: String
        let sessionID: String?
        /// `nil`: Zed's own agent. Otherwise an external ACP agent (`codex-acp`), whose store
        /// holds the conversation.
        let agentID: String?
        let title: String?
        let updatedAt: Date?
        let createdAt: Date?
        let folder: String?
        let isArchived: Bool
        let bytes: Int64
    }

    /// One `threads` row of threads.db.
    struct ThreadRow: Sendable, Hashable {
        let id: String
        let summary: String?
        let updatedAt: Date?
        let createdAt: Date?
        let folder: String?
        let dataBytes: Int64
        let dataType: String?
        let parentID: String?
    }

    /// A native thread as Domovy lists it: its threads.db row, its sidebar row, or both.
    struct Thread: Sendable {
        let id: String
        let row: ThreadRow?
        let sidebar: [SidebarRow]
        /// Subagent threads (`parent_id` = this id), which go with it.
        let children: [ThreadRow]

        var title: String? {
            [sidebar.first?.title, row?.summary].compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        var updatedAt: Date? { [row?.updatedAt, sidebar.first?.updatedAt].compactMap { $0 }.max() }
        var folder: String? { sidebar.first?.folder ?? row?.folder }
        var bytes: Int64 { (row?.dataBytes ?? 0) + children.reduce(0) { $0 + $1.dataBytes } + sidebar.reduce(0) { $0 + $1.bytes } }
    }

    var threads: [String: Thread] = [:]
    /// Sidebar rows of external agents, by session id (lowercased).
    var external: [String: SidebarRow] = [:]
    /// `thread_archived_worktrees`: worktree ids per sidebar thread (hex).
    var worktreeLinks: [String: [Int64]] = [:]

    static func load(_ layout: ZedLayout) -> ZedIndex {
        var index = ZedIndex()
        let rows = threadRows(layout)
        let sidebar = sidebarRows(layout)
        index.worktreeLinks = links(layout)

        var bySession: [String: [SidebarRow]] = [:]
        for row in sidebar {
            guard let session = row.sessionID?.lowercased(), !session.isEmpty else { continue } // drafts with nothing sent
            if let agent = row.agentID, !agent.isEmpty {
                index.external[session] = row
            } else {
                bySession[session, default: []].append(row)
            }
        }
        let children = Dictionary(grouping: rows.filter { $0.parentID != nil }) { $0.parentID?.lowercased() ?? "" }
        let roots = rows.filter { $0.parentID == nil }
        var ids = Set(bySession.keys)
        for row in roots { ids.insert(row.id.lowercased()) }
        for id in ids {
            let row = roots.first { $0.id.lowercased() == id }
            index.threads[id] = Thread(id: row?.id ?? id, row: row, sidebar: bySession[id] ?? [], children: children[id] ?? [])
        }
        return index
    }

    /// Session ids (lowercased) that Zed's sidebar lists for an external agent, with the agent:
    /// what another adapter (Codex) notes on its own sessions.
    static func externalSessions(workspaceDatabase: URL) -> [String: String] {
        guard FileSystem.exists(workspaceDatabase), let reader = SQLiteReader(url: workspaceDatabase),
              reader.columns(of: "sidebar_threads").isSuperset(of: ["session_id", "agent_id"]) else { return [:] }
        var result: [String: String] = [:]
        for row in reader.rows("SELECT session_id, agent_id FROM sidebar_threads WHERE agent_id IS NOT NULL AND session_id IS NOT NULL") {
            guard row.count == 2, let session = row[0], let agent = row[1], !agent.isEmpty else { continue }
            result[session.lowercased()] = agent
        }
        return result
    }

    // MARK: Rows

    private static func threadRows(_ layout: ZedLayout) -> [ThreadRow] {
        guard let reader = SQLiteReader(url: layout.threadsDatabase) else { return [] }
        let columns = reader.columns(of: "threads")
        guard columns.isSuperset(of: ZedLayout.threadsColumns) else { return [] }
        func optional(_ name: String) -> String { columns.contains(name) ? name : "NULL" }
        let sql = "SELECT id, summary, updated_at, \(optional("created_at")), \(optional("folder_paths")), length(data), data_type, \(optional("parent_id")) FROM threads"
        return reader.rows(sql).compactMap { row in
            guard row.count == 8, let id = row[0], !id.isEmpty else { return nil }
            return ThreadRow(id: id, summary: row[1], updatedAt: row[2].flatMap(date), createdAt: row[3].flatMap(date),
                             folder: row[4].flatMap(firstPath), dataBytes: row[5].flatMap { Int64($0) } ?? 0,
                             dataType: row[6], parentID: row[7].flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    private static func sidebarRows(_ layout: ZedLayout) -> [SidebarRow] {
        guard let reader = SQLiteReader(url: layout.workspaceDatabase) else { return [] }
        let columns = reader.columns(of: "sidebar_threads")
        guard columns.isSuperset(of: ZedLayout.sidebarColumns) else { return [] }
        func optional(_ name: String) -> String { columns.contains(name) ? name : "NULL" }
        let sql = """
            SELECT lower(hex(thread_id)), session_id, agent_id, title, \(optional("title_override")), updated_at,
                   \(optional("created_at")), \(optional("folder_paths")), archived,
                   length(thread_id) + coalesce(length(session_id), 0) + coalesce(length(title), 0) + coalesce(length(folder_paths), 0) + 64
            FROM sidebar_threads
            """
        return reader.rows(sql).compactMap { row in
            guard row.count == 10, let hex = row[0], !hex.isEmpty else { return nil }
            let title = [row[4], row[3]].compactMap { $0 }.first { !$0.isEmpty }
            return SidebarRow(threadHex: hex, sessionID: row[1], agentID: row[2], title: title, updatedAt: row[5].flatMap(date),
                              createdAt: row[6].flatMap(date), folder: row[7].flatMap(firstPath), isArchived: row[8] == "1",
                              bytes: row[9].flatMap { Int64($0) } ?? 0)
        }
    }

    private static func links(_ layout: ZedLayout) -> [String: [Int64]] {
        guard let reader = SQLiteReader(url: layout.workspaceDatabase),
              reader.columns(of: "thread_archived_worktrees").isSuperset(of: ZedLayout.linkColumns) else { return [:] }
        var result: [String: [Int64]] = [:]
        for row in reader.rows("SELECT lower(hex(thread_id)), archived_worktree_id FROM thread_archived_worktrees") {
            guard row.count == 2, let hex = row[0], let id = row[1].flatMap({ Int64($0) }) else { continue }
            result[hex, default: []].append(id)
        }
        return result
    }

    /// Archived worktree ids that `threads` link to and no other thread does.
    func orphanedWorktrees(removing gone: Set<String>) -> [Int64] {
        let removed = Set(gone.flatMap { worktreeLinks[$0] ?? [] })
        let kept = Set(worktreeLinks.filter { !gone.contains($0.key) }.flatMap(\.value))
        return removed.subtracting(kept).sorted()
    }

    // MARK: Values

    /// `folder_paths` holds one path per line; the first is the project.
    static func firstPath(_ text: String) -> String? {
        text.split(separator: "\n").first.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// RFC 3339 with up to nine fraction digits and an offset (`2026-11-12T21:53:12.123456+00:00`).
    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let dot = text.firstIndex(of: ".") else { return formatter.date(from: text) }
        var end = text.index(after: dot)
        while end < text.endIndex, text[end].isNumber { end = text.index(after: end) }
        let fraction = Double("0" + text[dot..<end]) ?? 0
        return formatter.date(from: String(text[..<dot]) + text[end...]).map { $0.addingTimeInterval(fraction) }
    }

    // MARK: Transcript

    /// Largest `data` blob read, and largest JSON it may decompress to. Real threads are far smaller.
    static let maxStoredBytes = 64 << 20
    static let maxThreadBytes: Int64 = 256 << 20

    /// A thread's `data` as JSON: as stored for `data_type` = `json`, decompressed for `zstd`.
    /// Throws a typed reason when the row is missing, of an unknown type, too large or damaged.
    static func jsonData(of id: String, in layout: ZedLayout) throws -> Data {
        guard let reader = SQLiteReader(url: layout.threadsDatabase),
              let type = reader.rows("SELECT data_type FROM threads WHERE id = ?1", [id]).first?.first ?? nil else {
            throw AdapterError.unreadable(layout.threadsDatabase, reason: "Zed's thread database has no conversation for this thread.")
        }
        guard type == "json" || type == "zstd" else {
            throw AdapterError.unreadable(layout.threadsDatabase, reason: "Zed stores this thread as \"\(type)\", a format Domovy does not know. Open it from Zed's Thread History.")
        }
        guard let stored = reader.blob("SELECT data FROM threads WHERE id = ?1", [id], maxBytes: maxStoredBytes) else {
            throw AdapterError.unreadable(layout.threadsDatabase, reason: "The thread is too large to preview. Open it from Zed's Thread History.")
        }
        guard type == "zstd" else { return stored }
        do {
            return try Zstd.decompress(stored, limit: maxThreadBytes)
        } catch {
            throw AdapterError.unreadable(layout.threadsDatabase, reason: "\(error.localizedDescription) Open it from Zed's Thread History.")
        }
    }

    /// Messages of Zed's thread JSON: `messages` is a list of `{User: {content}}` and
    /// `{Agent: {content}}`, each content a list of `{Text: …}`, `{ToolUse: {name}}` and others.
    static func transcript(_ data: Data, limit: Int) -> Transcript {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = object["messages"] as? [[String: Any]] else { return .empty }
        var result: [TranscriptMessage] = []
        for (index, message) in messages.enumerated() {
            let role: TranscriptMessage.Role
            let body: [String: Any]
            if let user = message["User"] as? [String: Any] {
                role = .user
                body = user
            } else if let agent = message["Agent"] as? [String: Any] {
                role = .assistant
                body = agent
            } else { continue }
            var blocks: [TranscriptMessage.Block] = []
            for part in body["content"] as? [Any] ?? [] {
                if let text = part as? String {
                    blocks.append(.text(text))
                } else if let part = part as? [String: Any] {
                    if let text = part["Text"] as? String {
                        blocks.append(.text(text))
                    } else if let tool = part["ToolUse"] as? [String: Any] {
                        blocks.append(.toolCall((tool["name"] as? String) ?? "Tool call"))
                    }
                }
            }
            guard !blocks.isEmpty else { continue }
            if result.count == limit { return Transcript(messages: result, isTruncated: true) }
            result.append(TranscriptMessage(id: "\(index)", role: role, timestamp: nil, blocks: blocks))
        }
        return Transcript(messages: result, isTruncated: false)
    }
}
