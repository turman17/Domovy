import Foundation

/// Codex's indexes, read once per scan: `session_index.jsonl` (`{id, thread_name, updated_at}`,
/// latest entry wins), `history.jsonl` (`{session_id, ts, text}`) and the `threads` table of
/// `state_5.sqlite`. All read-only; Domovy never writes to Codex's databases.
struct CodexIndex: Sendable {
    struct Lines: Sendable {
        var count = 0
        var bytes: Int64 = 0
    }

    struct Thread: Sendable {
        let title: String?
        let cwd: String?
    }

    static let sessionIndexKey = "id"
    static let historyKey = "session_id"

    var names: [String: String] = [:]
    var sessionIndexLines: [String: Lines] = [:]
    var historyLines: [String: Lines] = [:]
    var threads: [String: Thread] = [:]

    static func load(_ layout: CodexLayout) -> CodexIndex {
        var index = CodexIndex()
        var names: [String: String] = [:]
        index.sessionIndexLines = lineCounts(layout.sessionIndex, key: sessionIndexKey) { id, object in
            if let name = object["thread_name"] as? String, let title = CodexRollout.cleanTitle(name) { names[id] = title }
        }
        index.names = names
        index.historyLines = lineCounts(layout.history, key: historyKey)
        if let db = SQLiteReader(url: layout.stateDatabase) {
            for row in db.rows("SELECT id, title, cwd FROM threads") {
                guard row.count == 3, let id = row[0]?.lowercased() else { continue }
                let cwd = row[2].flatMap { $0.isEmpty ? nil : $0 }
                index.threads[id] = Thread(title: row[1].flatMap(CodexRollout.cleanTitle), cwd: cwd)
            }
        }
        return index
    }

    private static func lineCounts(_ url: URL, key: String, visit: (String, [String: Any]) -> Void = { _, _ in }) -> [String: Lines] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        var result: [String: Lines] = [:]
        for line in JSONLines.split(data).lines {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = (object[key] as? String)?.lowercased() else { continue }
            result[id, default: Lines()].count += 1
            result[id, default: Lines()].bytes += Int64(line.count) + 1
            visit(id, object)
        }
        return result
    }

    /// Lines of `file` whose `key` equals `id`, as a plan edit; `nil` when there are none.
    static func edit(_ file: URL, key: String, id: String) -> IndexEdit? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let split = JSONLines.split(data)
        let indices = JSONLines.indices(in: split.lines, where: key, equals: id)
        guard !indices.isEmpty else { return nil }
        let bytes = indices.reduce(Int64(0)) { $0 + Int64(split.lines[$1].count) + 1 }
        let n = indices.count
        return IndexEdit(
            file: file,
            lineNumbers: indices,
            matchKey: key,
            matchValue: id,
            removedBytes: bytes,
            note: "\(n) \(n == 1 ? "entry" : "entries") in \(file.lastPathComponent); the file itself stays"
        )
    }

    // MARK: Database rows

    /// Tables keyed by thread id, per database, from the schemas of a real install (0.169).
    static let threadTables: [(file: String, tables: [(table: String, column: String)])] = [
        ("state_5.sqlite", [
            ("threads", "id"), ("thread_spawn_edges", "parent_thread_id"), ("thread_spawn_edges", "child_thread_id"),
            ("thread_attachments", "thread_id"), ("thread_dynamic_tools", "thread_id"), ("thread_read_receipts", "thread_id"),
        ]),
        ("thread_history_1.sqlite", [
            ("thread_turns", "thread_id"), ("thread_items", "thread_id"), ("thread_realtime_items", "thread_id"),
            ("thread_history_projection_state", "thread_id"),
        ]),
        ("goals_1.sqlite", [("thread_goals", "thread_id")]),
        ("memories_1.sqlite", [("stage1_outputs", "thread_id")]),
        ("queue_1.sqlite", [("queued_items", "thread_id")]),
        ("logs_2.sqlite", [("logs", "thread_id")]),
        ("sqlite/codex.db", [("local_thread_catalog", "thread_id"), ("thread_timeline_ledger", "thread_id"), ("inbox_items", "thread_id")]),
    ]

    struct DatabaseRows: Sendable {
        let database: URL
        /// Table name and matching row count, only tables with rows.
        let tables: [(table: String, column: String, count: Int)]
        var total: Int { tables.reduce(0) { $0 + $1.count } }

        var note: String {
            let n = total
            let names = Array(NSOrderedSet(array: tables.map(\.table))).compactMap { $0 as? String }.joined(separator: ", ")
            return "\(n) \(n == 1 ? "row" : "rows") in \(database.lastPathComponent) (\(names)); Domovy never edits Codex's databases"
        }
    }

    /// Rows that reference the thread, per database that has any.
    static func databaseRows(root: URL, id: String) -> [DatabaseRows] {
        threadTables.compactMap { spec in
            let url = root.appendingPathComponent(spec.file)
            guard let db = SQLiteReader(url: url) else { return nil }
            let present = db.tables()
            let counts = spec.tables.compactMap { table, column -> (String, String, Int)? in
                guard present.contains(table), let n = db.count(table: table, column: column, equals: id), n > 0 else { return nil }
                return (table, column, n)
            }
            return counts.isEmpty ? nil : DatabaseRows(database: url, tables: counts.map { (table: $0.0, column: $0.1, count: $0.2) })
        }
    }
}
