import Foundation
import SQLite3

/// Read-only access to an agent's SQLite database through the system `libsqlite3`.
/// Opens with `SQLITE_OPEN_READONLY` only; there is no code path that writes (safety rule 4).
/// Row contents read here may hold user text: callers show it, never log it.
final class SQLiteReader {
    private let db: OpaquePointer

    /// Opens `url` read-only. Falls back to `immutable=1` when a WAL database cannot be
    /// opened read-only (its `-shm` is not readable); that view may miss the newest writes.
    init?(url: URL) {
        guard FileSystem.exists(url) else { return nil }
        let path = url.standardizedFileURL.path
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        for uri in ["file:\(encoded)?mode=ro", "file:\(encoded)?mode=ro&immutable=1"] {
            var handle: OpaquePointer?
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
            if sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK, let handle {
                sqlite3_busy_timeout(handle, 200)
                if Self.probe(handle) {
                    db = handle
                    return
                }
            }
            sqlite3_close_v2(handle)
        }
        Log.adapter.info("Could not open \(url.lastPathComponent, privacy: .private) read-only")
        return nil
    }

    deinit {
        sqlite3_close_v2(db)
    }

    private static func probe(_ handle: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, "SELECT count(*) FROM sqlite_master", -1, &statement, nil) == SQLITE_OK else { return false }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// Names of tables in the database.
    func tables() -> Set<String> {
        Set(rows("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0.first ?? nil })
    }

    /// Rows where `column` equals `value`, or `nil` when the query failed (missing table or column).
    func count(table: String, column: String, equals value: String) -> Int? {
        guard Self.isIdentifier(table), Self.isIdentifier(column) else { return nil }
        let result = query("SELECT count(*) FROM \"\(table)\" WHERE \"\(column)\" = ?1", [value])
        return result?.first?.first.flatMap { $0 }.flatMap { Int($0) }
    }

    /// All rows of a query as text, `nil` cells for NULL. Empty on failure.
    func rows(_ sql: String, _ arguments: [String] = []) -> [[String?]] {
        query(sql, arguments) ?? []
    }

    private func query(_ sql: String, _ arguments: [String]) -> [[String?]]? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, argument) in arguments.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), argument, -1, transient)
        }
        var result: [[String?]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return nil }
            let columns = sqlite3_column_count(statement)
            result.append((0..<columns).map { index in
                sqlite3_column_text(statement, index).map { String(cString: $0) }
            })
        }
        return result
    }

    /// Table and column names come from adapter constants; refuse anything else.
    private static func isIdentifier(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0 == "_" || $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
