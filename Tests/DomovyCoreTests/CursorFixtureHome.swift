@testable import DomovyCore
import Foundation

/// A throwaway home with Cursor's folders copied from `Tests/Fixtures/cursor/3.0/`, the global
/// `state.vscdb` built from `Tests/Fixtures/cursor/sql/state.sql`, and a CLI chat whose
/// `store.db` is built here. Never the real Cursor database.
final class CursorFixtureHome: Sendable {
    enum IDs {
        /// Named, every kind of per-chat row, a plain-text copy in ~/.cursor/projects.
        static let named = "ca11ab1e-1111-4111-8111-111111111111"
        /// No name: titled by its first prompt.
        static let untitled = "cafe0002-2222-4222-8222-222222222222"
        static let small = "cab00003-3333-4333-8333-333333333333"
        static let emptyDraft = "cade0004-4444-4444-8444-444444444444"
        static let cli = "2c3d4e5f-1111-4111-8111-111111111111"
    }

    let home: URL
    let storeRoot: URL
    var support: URL { home.appendingPathComponent("Library/Application Support/Cursor", isDirectory: true) }
    var dot: URL { home.appendingPathComponent(".cursor", isDirectory: true) }
    var database: URL { support.appendingPathComponent("User/globalStorage/state.vscdb") }
    var cliChat: URL { dot.appendingPathComponent("chats/4e5f6a7b/\(IDs.cli)", isDirectory: true) }
    var agentTranscript: URL { dot.appendingPathComponent("projects/Users-dev-code-orbit-api/agent-transcripts/\(IDs.named).txt") }

    init() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("domovy-cursor-tests-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        storeRoot = base.appendingPathComponent("store", isDirectory: true)
        let fixtures = FixtureHome.fixturesRoot.appendingPathComponent("cursor", isDirectory: true)
        try fm.createDirectory(at: support.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: fixtures.appendingPathComponent("3.0/support", isDirectory: true), to: support)
        try fm.copyItem(at: fixtures.appendingPathComponent("3.0/dot-cursor", isDirectory: true), to: dot)
        try fm.removeItem(at: database)
        try CodexFixtureHome.buildDatabase(String(contentsOf: fixtures.appendingPathComponent("sql/state.sql"), encoding: .utf8), at: database)

        let store = cliChat.appendingPathComponent("store.db")
        try fm.removeItem(at: store)
        let meta = #"{"agentId":"2c3d4e5f-1111-4111-8111-111111111111","name":"Rename the CLI flags","createdAt":1795100000000}"#
        let bulk = String(repeating: "synthetic agent step, compiled without warnings. ", count: 2_000)
        try CodexFixtureHome.buildDatabase("""
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB);
            INSERT INTO meta VALUES ('0', hex('\(meta)'));
            INSERT INTO blobs VALUES ('b1', '\(bulk)');
            """, at: store)

        try fm.createDirectory(at: agentTranscript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("user: The upload test fails one run in ten.\n".utf8).write(to: agentTranscript)
    }

    deinit {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    /// Deterministic: Cursor quit and nothing open unless told otherwise.
    func adapter(running: [RunningProcess]? = [], holders: [OpenHandleHolder] = []) -> CursorAdapter {
        CursorAdapter(supportDirectory: support, dotDirectory: dot,
                      openHandles: FixedOpenHandleChecker(holders: holders), processes: FixedProcessLister(running))
    }

    func executor(running: [RunningProcess]? = [], openFiles: [Int32: [String]] = [:],
                  integrity: any DatabaseIntegrityChecker = SQLiteIntegrityChecker()) -> Executor {
        Executor(storeRoot: storeRoot, processes: FixedProcessLister(running, openFiles: openFiles), integrity: integrity)
    }

    func count(_ prefix: String) -> Int {
        let reader = SQLiteReader(url: database)
        let rows = reader?.rows("SELECT count(*) FROM cursorDiskKV WHERE substr(key, 1, ?2) = ?1", [prefix, String(prefix.count)])
        return rows?.first?.first.flatMap { $0 }.flatMap { Int($0) } ?? -1
    }

    func value(_ key: String, table: String = "ItemTable") -> String? {
        SQLiteReader(url: database)?.rows("SELECT CAST(value AS TEXT) FROM \(table) WHERE key = ?1", [key]).first?.first ?? nil
    }

    func pragma(_ name: String) -> String? {
        SQLiteReader(url: database)?.rows("PRAGMA \(name)").first?.first ?? nil
    }

    /// Something else writes to the database, the way Cursor would after it starts again.
    func write(_ sql: String) throws {
        try CodexFixtureHome.buildDatabase(sql, at: database)
    }
}

/// Reports a broken database, so the executor must put its copy back.
struct FailingIntegrityChecker: DatabaseIntegrityChecker {
    func problems(in database: URL) -> [String]? {
        ["*** in database main ***\nPage 7: btreeInitPage() returns error code 11"]
    }
}
