import Foundation

/// Paths of OpenCode's data folder, `~/.local/share/opencode` (verified on 1.18.30): every
/// session lives in one SQLite database, `opencode.db` with `-wal` and `-shm`, next to `log/`,
/// `snapshot/` (git repositories behind its file undo) and `repos/`. Settings live in
/// `~/.config/opencode`. Older versions kept sessions as JSON files under `storage/`.
struct OpenCodeLayout: Sendable {
    /// `~/.local/share/opencode`.
    let root: URL
    /// `~/.config/opencode`.
    let config: URL

    var database: URL { root.appendingPathComponent("opencode.db") }
    /// The database and its journal files, which OpenCode's own commands rewrite in place.
    var databaseFiles: [URL] { ["", "-wal", "-shm"].map { root.appendingPathComponent("opencode.db" + $0) } }
    var snapshots: URL { root.appendingPathComponent("snapshot", isDirectory: true) }
    var logs: URL { root.appendingPathComponent("log", isDirectory: true) }
    /// Older versions' JSON storage. `storage/session_diff/<id>.json` is per session (assumed).
    var storage: URL { root.appendingPathComponent("storage", isDirectory: true) }

    func sessionDiff(_ id: String) -> URL {
        storage.appendingPathComponent("session_diff/\(id).json")
    }

    /// Entries OpenCode needs to run. Its database also holds sign-ins (`account`, `credential`),
    /// so it is never moved as a whole.
    static let protectedEntries: Set<String> = [
        "opencode.db", "opencode.db-wal", "opencode.db-shm", "auth.json", "mcp-auth.json", "bin",
    ]

    /// Columns Domovy reads, as verified on 1.18.30. Anything missing makes the adapter read-only.
    static let requiredColumns: [String: Set<String>] = [
        "session": ["id", "title", "directory", "time_created", "time_updated", "parent_id"],
        "message": ["id", "session_id", "time_created", "data"],
        "part": ["id", "message_id", "session_id", "data"],
    ]

    func isProtected(_ url: URL) -> Bool {
        guard let relative = FileSystem.relativePath(of: url, under: root) else { return false }
        guard let first = relative.split(separator: "/").first.map(String.init) else { return true }
        return Self.protectedEntries.contains(first)
    }

    func probe() -> AdapterStatus {
        guard FileSystem.isDirectory(root) else { return .notInstalled }
        guard FileSystem.exists(database) else {
            if FileSystem.isDirectory(storage.appendingPathComponent("session", isDirectory: true)) {
                return .readOnly(reason: "This OpenCode keeps sessions as JSON files in storage/, a layout Domovy does not know yet.")
            }
            return .ready
        }
        guard let reader = SQLiteReader(url: database) else {
            return .readOnly(reason: "Domovy could not open opencode.db read-only.")
        }
        for (table, columns) in Self.requiredColumns.sorted(by: { $0.key < $1.key }) {
            let missing = columns.subtracting(reader.columns(of: table))
            if !missing.isEmpty {
                return .readOnly(reason: "opencode.db has a layout Domovy does not know (\(table) lacks \(missing.sorted().joined(separator: ", "))), so it only shows what it can read.")
            }
        }
        return .ready
    }
}
