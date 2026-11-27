import Foundation
import SQLite3

/// Domovy's own SQLite file for the transcript index: never another app's database. The
/// folder is 0700 and the file 0600 (its journal files take the file's mode), and the folder
/// is left out of backups. Statements bind every value; row text is never logged.
final class SearchDatabase {
    struct Failure: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    private let db: OpaquePointer

    init(file: URL) throws {
        let fm = FileManager.default
        let folder = file.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(folder.path, 0o700)
        var folderURL = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folderURL.setResourceValues(values)
        // Created 0600 before SQLite opens it, so its -wal and -shm files are 0600 too.
        let descriptor = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure(reason: "Domovy could not create its search index file.") }
        close(descriptor)
        chmod(file.path, 0o600)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(file.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            sqlite3_close_v2(handle)
            throw Failure(reason: "Domovy could not open its search index.")
        }
        db = handle
        sqlite3_busy_timeout(db, 3_000)
    }

    deinit {
        sqlite3_close_v2(db)
    }

    enum Value {
        case text(String)
        case integer(Int64)
        case null
    }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    /// Runs a statement that returns no rows.
    func run(_ sql: String, _ values: [Value] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    /// Rows of a query, each column as text, integer or real.
    func rows(_ sql: String, _ values: [Value] = []) throws -> [[Cell]] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        var result: [[Cell]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw failure() }
            result.append((0..<sqlite3_column_count(statement)).map { Cell(statement, $0) })
        }
        return result
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(db) }

    /// A prepared statement run many times with new values (the per-message insert).
    final class Statement {
        fileprivate let handle: OpaquePointer
        private let database: SearchDatabase

        fileprivate init(_ handle: OpaquePointer, _ database: SearchDatabase) {
            self.handle = handle
            self.database = database
        }

        deinit { sqlite3_finalize(handle) }

        func run(_ values: [Value]) throws {
            sqlite3_reset(handle)
            sqlite3_clear_bindings(handle)
            database.bind(handle, values)
            guard sqlite3_step(handle) == SQLITE_DONE else { throw database.failure() }
        }
    }

    func statement(_ sql: String) throws -> Statement {
        Statement(try prepare(sql), self)
    }

    struct Cell {
        let text: String?
        let integer: Int64
        let real: Double

        init(_ statement: OpaquePointer, _ index: Int32) {
            text = sqlite3_column_text(statement, index).map { String(cString: $0) }
            integer = sqlite3_column_int64(statement, index)
            real = sqlite3_column_double(statement, index)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw failure()
        }
        return statement
    }

    fileprivate func bind(_ statement: OpaquePointer, _ values: [Value]) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, position, text, -1, transient)
            case .integer(let number): sqlite3_bind_int64(statement, position, number)
            case .null: sqlite3_bind_null(statement, position)
            }
        }
    }

    /// SQLite's own message ("database is locked"), never row content.
    fileprivate func failure() -> Failure {
        Failure(reason: "The search index could not be updated: \(String(cString: sqlite3_errmsg(db))).")
    }
}
