import Foundation

/// Rows Domovy deletes from an app's SQLite database itself, because the app has no command for
/// one item (Cursor's `state.vscdb`). The executor runs it only while nothing holds the files
/// open, clones the whole database first, checks `PRAGMA integrity_check` afterwards and puts
/// the clone back when that fails. Undo puts the clone back only while the database is exactly
/// as the edit left it. Never VACUUM: the space stays inside the file for the app to reuse.
public struct DatabaseEdit: Hashable, Codable, Sendable {
    /// How `Rows.key` is compared with its column.
    public enum KeyEncoding: String, Hashable, Codable, Sendable {
        case text
        /// `key` is hex; the column holds those bytes as a BLOB (Zed's 16-byte `thread_id`).
        case hexBlob
        /// `key` is a decimal integer (an `INTEGER PRIMARY KEY`).
        case integer
    }

    /// Rows of a key-value table whose `key` equals `key`, or starts with it when `isPrefix`.
    /// `column` names another key column (Antigravity's `conversation_id`).
    public struct Rows: Hashable, Codable, Sendable {
        public let table: String
        public let key: String
        /// `nil`: the column is `key`.
        public let column: String?
        public let isPrefix: Bool
        /// `nil`: text. Prefixes are text only.
        public let encoding: KeyEncoding?
        /// At plan time; the executor deletes whatever matches when it runs.
        public let count: Int
        public let bytes: Int64
        public let note: String

        public init(table: String, key: String, isPrefix: Bool, count: Int, bytes: Int64, note: String, column: String? = nil,
                    encoding: KeyEncoding? = nil) {
            self.table = table
            self.key = key
            self.column = column
            self.isPrefix = isPrefix
            self.encoding = encoding
            self.count = count
            self.bytes = bytes
            self.note = note
        }
    }

    /// One value of a key-value table holding a JSON list (Cursor's `composer.composerHeaders`):
    /// the entries whose `idField` is `id` are cut out; every other byte stays as it was.
    /// With `memberPath`, the value is an object instead, and the member keyed `id` of the object
    /// at that path is cut out (VS Code's `chat.ChatSessionStore.index` → `entries` → `<id>`).
    public struct ListEntryRemoval: Hashable, Codable, Sendable {
        public let table: String
        public let key: String
        /// The member of the top-level object that holds the list; `nil` when the value is the list.
        public let listField: String?
        public let idField: String
        public let id: String
        public let note: String
        /// Members from the top-level object down to the object that holds the member `id`.
        public let memberPath: [String]?
        /// Bytes of what is cut, at plan time, when it is more than a list entry's few bytes.
        public let bytes: Int64?

        public init(table: String, key: String, listField: String?, idField: String, id: String, note: String) {
            self.table = table
            self.key = key
            self.listField = listField
            self.idField = idField
            self.id = id
            self.note = note
            self.memberPath = nil
            self.bytes = nil
        }

        /// Cuts the member `id` of the object at `path` inside the JSON value of `key`.
        public init(table: String, key: String, memberPath path: [String], id: String, bytes: Int64, note: String) {
            self.table = table
            self.key = key
            self.listField = nil
            self.idField = ""
            self.id = id
            self.note = note
            self.memberPath = path
            self.bytes = bytes
        }
    }

    public let database: URL
    /// The database and its `-wal` and `-shm`: cloned first, and nothing may hold them open.
    public let files: [URL]
    public let rows: [Rows]
    public let listRemovals: [ListEntryRemoval]

    public init(database: URL, files: [URL], rows: [Rows], listRemovals: [ListEntryRemoval]) {
        self.database = database
        self.files = files
        self.rows = rows
        self.listRemovals = listRemovals
    }

    public var rowCount: Int { rows.reduce(0) { $0 + $1.count } }
    public var sizeBytes: Int64 { rows.reduce(0) { $0 + $1.bytes } + listRemovals.reduce(0) { $0 + ($1.bytes ?? 0) } }
    public var isEmpty: Bool { rowCount == 0 && listRemovals.isEmpty }
}

/// Checks a database after Domovy wrote to it. Tests inject one that fails on purpose.
public protocol DatabaseIntegrityChecker: Sendable {
    /// What `PRAGMA integrity_check` reported: empty when the database is intact, `nil` when the
    /// check could not run (which counts as a failure).
    func problems(in database: URL) -> [String]?
}

/// `PRAGMA integrity_check` on a read-only connection.
public struct SQLiteIntegrityChecker: DatabaseIntegrityChecker {
    public init() {}

    public func problems(in database: URL) -> [String]? {
        guard let reader = SQLiteReader(url: database) else { return nil }
        let result = reader.rows("PRAGMA integrity_check").compactMap { $0.first ?? nil }
        guard !result.isEmpty else { return nil }
        return result == ["ok"] ? [] : result
    }
}
