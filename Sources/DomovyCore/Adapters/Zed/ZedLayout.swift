import Foundation

/// Paths of Zed's Agent Panel storage, verified on Zed 1.29.3 (docs/research/agent_storage_formats.md, Q8):
/// native threads are rows of `Zed/threads/threads.db` (`threads`, one zstd-compressed JSON
/// `data` per thread), and the sidebar lists every thread, native or from an external ACP agent,
/// as a row of `sidebar_threads` in the workspace database `Zed/db/0-stable/db.sqlite`. That file
/// is Zed's whole workspace state, so Domovy only ever deletes rows of `sidebar_threads` and of
/// the two archived-worktree tables in it.
struct ZedLayout: Sendable {
    /// `~/Library/Application Support/Zed`.
    let support: URL

    var threadsFolder: URL { support.appendingPathComponent("threads", isDirectory: true) }
    var threadsDatabase: URL { threadsFolder.appendingPathComponent("threads.db") }
    var workspaceDatabase: URL { support.appendingPathComponent("db/0-stable/db.sqlite") }
    /// The LMDB store Zed used before threads.db; no longer written.
    var legacyThreads: URL { threadsFolder.appendingPathComponent("threads-db.1.mdb", isDirectory: true) }

    var threadsFiles: [URL] { SharedDatabaseLiveness.files(of: threadsDatabase) }
    var workspaceFiles: [URL] { SharedDatabaseLiveness.files(of: workspaceDatabase) }
    var databaseFiles: [URL] { threadsFiles + workspaceFiles }

    /// The tables and columns Domovy reads and edits, as verified.
    static let threadsColumns: Set<String> = ["id", "summary", "updated_at", "data_type", "data"]
    static let sidebarColumns: Set<String> = ["thread_id", "session_id", "agent_id", "title", "updated_at", "archived"]
    static let linkColumns: Set<String> = ["thread_id", "archived_worktree_id"]
    static let worktreeColumns: Set<String> = ["id", "worktree_path"]

    /// Zed (`Zed.app/Contents/MacOS/zed`; Zed Preview's executable has the same name).
    static let appMatcher = ProcessMatcher(
        appName: "Zed", names: ["zed"],
        quitAdvice: "Quit Zed (Zed \u{203A} Quit Zed) to change its threads."
    )

    static func home(_ home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Zed", isDirectory: true)
    }

    // MARK: Probe

    func probe() -> AdapterStatus {
        guard FileSystem.exists(threadsDatabase) || FileSystem.exists(workspaceDatabase) else { return .notInstalled }
        if let reason = unknownLayout() { return .readOnly(reason: reason) }
        return .ready
    }

    /// Why Domovy does not understand the databases, or `nil`.
    func unknownLayout() -> String? {
        if FileSystem.exists(threadsDatabase) {
            guard let reader = SQLiteReader(url: threadsDatabase) else { return "Domovy could not open Zed's threads.db read-only." }
            guard reader.columns(of: "threads").isSuperset(of: Self.threadsColumns) else {
                return "Zed's threads.db has a layout Domovy does not know (no threads table with id, summary and data), so it only shows what it can read."
            }
        }
        if FileSystem.exists(workspaceDatabase) {
            guard let reader = SQLiteReader(url: workspaceDatabase) else { return "Domovy could not open Zed's workspace database read-only." }
            let tables = reader.tables()
            guard tables.contains("sidebar_threads"), reader.columns(of: "sidebar_threads").isSuperset(of: Self.sidebarColumns) else {
                return "Zed's thread sidebar (sidebar_threads) has a layout Domovy does not know, so it does not change Zed's threads."
            }
            if tables.contains("thread_archived_worktrees"), !reader.columns(of: "thread_archived_worktrees").isSuperset(of: Self.linkColumns) {
                return "Zed's archived worktree table has a layout Domovy does not know, so it does not change Zed's threads."
            }
            if tables.contains("archived_git_worktrees"), !reader.columns(of: "archived_git_worktrees").isSuperset(of: Self.worktreeColumns) {
                return "Zed's archived worktree table has a layout Domovy does not know, so it does not change Zed's threads."
            }
        }
        return nil
    }
}
