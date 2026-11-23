import Foundation
import SQLite3

/// The one place Domovy writes to another app's SQLite database (safety rule 4). Only the
/// executor uses it, for a `DatabaseEdit`, after it checked the app is quit, nothing holds the
/// files open and a clone of the database exists. It runs a fixed set of statements: `DELETE`
/// by key and `UPDATE` of one value, inside `BEGIN IMMEDIATE … COMMIT`. Never `VACUUM`.
enum SQLiteWriter {
    struct Failure: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Rows actually deleted and list entries actually removed.
    struct Outcome: Equatable {
        var rows = 0
        var listEntries = 0
    }

    static func apply(_ edit: DatabaseEdit) throws -> Outcome {
        var handle: OpaquePointer?
        // No SQLITE_OPEN_CREATE: a missing database is an error, never a new empty file.
        guard sqlite3_open_v2(edit.database.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close_v2(handle)
            throw Failure(reason: "it could not be opened for writing")
        }
        defer { sqlite3_close_v2(db) }
        // No waiting: anything else writing means the app is not really quit.
        sqlite3_busy_timeout(db, 0)
        try exec(db, "BEGIN IMMEDIATE")
        do {
            var outcome = Outcome()
            for rows in edit.rows {
                outcome.rows += try delete(rows, in: db)
            }
            for removal in edit.listRemovals {
                outcome.listEntries += try remove(removal, in: db)
            }
            try exec(db, "COMMIT")
            return outcome
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private static func delete(_ rows: DatabaseEdit.Rows, in db: OpaquePointer) throws -> Int {
        let table = try identifier(rows.table)
        if rows.isPrefix {
            guard let upper = upperBound(of: rows.key) else { throw Failure(reason: "a key prefix Domovy cannot bound") }
            try run(db, "DELETE FROM \"\(table)\" WHERE key >= ?1 AND key < ?2", [.text(rows.key), .text(upper)])
        } else {
            try run(db, "DELETE FROM \"\(table)\" WHERE key = ?1", [.text(rows.key)])
        }
        return Int(sqlite3_changes(db))
    }

    /// Reads the value now (not at plan time), cuts the entries out and writes it back with the
    /// same storage class (text or blob).
    private static func remove(_ removal: DatabaseEdit.ListEntryRemoval, in db: OpaquePointer) throws -> Int {
        let table = try identifier(removal.table)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM \"\(table)\" WHERE key = ?1", -1, &statement, nil) == SQLITE_OK else {
            throw Failure(reason: message(db))
        }
        bind(statement, [.text(removal.key)])
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        let isBlob = sqlite3_column_type(statement, 0) == SQLITE_BLOB
        let count = Int(sqlite3_column_bytes(statement, 0))
        let data = sqlite3_column_blob(statement, 0).map { Data(bytes: $0, count: count) } ?? Data()
        sqlite3_finalize(statement)
        statement = nil
        guard let cut = JSONListCut.removing(from: data, field: removal.listField, idField: removal.idField, id: removal.id) else {
            throw Failure(reason: "its chat list has a shape Domovy does not know")
        }
        guard cut.removed > 0 else { return 0 }
        let value: Value = isBlob ? .blob(cut.data) : .text(String(decoding: cut.data, as: UTF8.self))
        try run(db, "UPDATE \"\(table)\" SET value = ?1 WHERE key = ?2", [value, .text(removal.key)])
        return cut.removed
    }

    /// The smallest string above every string that starts with `prefix` (its last ASCII
    /// character raised by one), so a prefix becomes an indexed key range.
    static func upperBound(of prefix: String) -> String? {
        guard let last = prefix.unicodeScalars.last, last.isASCII, last.value < 0x7F,
              let next = Unicode.Scalar(last.value + 1) else { return nil }
        return String(prefix.unicodeScalars.dropLast()) + String(next)
    }

    // MARK: Statements

    private enum Value {
        case text(String)
        case blob(Data)
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure(reason: message(db)) }
    }

    private static func run(_ db: OpaquePointer, _ sql: String, _ values: [Value]) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw Failure(reason: message(db)) }
        bind(statement, values)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure(reason: message(db)) }
    }

    private static func bind(_ statement: OpaquePointer?, _ values: [Value]) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            switch value {
            case .text(let text):
                sqlite3_bind_text(statement, Int32(index + 1), text, -1, transient)
            case .blob(let data):
                _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, Int32(index + 1), $0.baseAddress, Int32(data.count), transient) }
            }
        }
    }

    /// SQLite's own message (never row content): "database is locked", "disk I/O error".
    private static func message(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }

    private static func identifier(_ name: String) throws -> String {
        guard !name.isEmpty, name.allSatisfy({ $0 == "_" || $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw Failure(reason: "an unexpected table name")
        }
        return name
    }
}
