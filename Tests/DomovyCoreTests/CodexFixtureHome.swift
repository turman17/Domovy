import DomovyCore
import Foundation
import SQLite3

/// A throwaway home with `.codex` copied from `Tests/Fixtures/codex/<version>/`, its SQLite
/// databases built from `Tests/Fixtures/codex/sql/`, and the stub CLI at `<base>/bin/codex`.
final class CodexFixtureHome: Sendable {
    enum IDs {
        static let idle = "01a1f011-1111-7111-8111-111111111111"
        static let segment = "01a1f0aa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
        static let live = "01a1f022-2222-7222-8222-222222222222"
        static let compressed = "01a1f033-3333-7333-8333-333333333333"
        static let archived = "01a1f044-4444-7444-8444-444444444444"
        static let bare = "01a1f055-5555-7555-8555-555555555555"
    }

    static let idleRollout = "sessions/2026/11/20/rollout-2026-11-20T09-15-00-\(IDs.idle).jsonl"
    static let idleSegment = "sessions/2026/11/20/rollout-2026-11-20T11-40-00-\(IDs.idle)_\(IDs.segment).jsonl"
    static let liveRollout = "sessions/2026/11/22/rollout-2026-11-22T08-00-00-\(IDs.live).jsonl"

    let home: URL
    let storeRoot: URL
    let stub: URL
    var codexDirectory: URL { home.appendingPathComponent(".codex", isDirectory: true) }

    init(version: String = "0.169", now: Date = Date()) throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("domovy-codex-tests-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        storeRoot = base.appendingPathComponent("store", isDirectory: true)
        stub = base.appendingPathComponent("bin/codex")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let fixtures = FixtureHome.fixturesRoot.appendingPathComponent("codex", isDirectory: true)
        try fm.copyItem(at: fixtures.appendingPathComponent(version, isDirectory: true), to: codexDirectory)
        for name in ["state_5", "thread_history_1"] {
            let sql = try String(contentsOf: fixtures.appendingPathComponent("sql/\(name).sql"), encoding: .utf8)
            try Self.buildDatabase(sql, at: codexDirectory.appendingPathComponent("\(name).sqlite"))
        }
        try fm.createDirectory(at: stub.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: fixtures.appendingPathComponent("stub-codex.sh"), to: stub)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let day: TimeInterval = 86_400
        try setDate(Self.idleRollout, now.addingTimeInterval(-2 * day))
        try setDate(Self.idleSegment, now.addingTimeInterval(-2 * day + 3_600))
        try setDate(Self.liveRollout, now.addingTimeInterval(-600))
    }

    deinit {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    /// Tests build their databases; Domovy itself only ever reads them.
    static func buildDatabase(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    /// Deterministic: no libproc, no running Codex, and the stub CLI unless told otherwise.
    /// - Parameters:
    ///   - running: Codex processes; `nil` means the process list could not be read.
    ///   - openFiles: paths each pid holds open; pids not listed hold nothing.
    func adapter(
        cli: CodexCLI.Choice? = nil,
        openHandles: any OpenHandleChecker = UnavailableOpenHandleChecker(),
        running: [RunningProcess]? = [],
        openFiles: [Int32: [String]] = [:],
        unreadable: Set<Int32> = []
    ) -> CodexAdapter {
        CodexAdapter(codexHome: codexDirectory, cli: cli ?? .executable(stub), openHandles: openHandles,
                     processes: FixedProcessLister(running, openFiles: openFiles, unreadable: unreadable))
    }

    func executor(running: [RunningProcess]? = [], openFiles: [Int32: [String]] = [:]) -> Executor {
        Executor(storeRoot: storeRoot, processes: FixedProcessLister(running, openFiles: openFiles))
    }

    /// A file below this fixture's CODEX_HOME, as a Codex process would hold it open.
    var openStateDatabase: String { url("state_5.sqlite").standardizedFileURL.path }

    func url(_ relative: String) -> URL { codexDirectory.appendingPathComponent(relative) }
    func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: url(relative).path) }
    func contents(_ relative: String) throws -> String { try String(contentsOf: url(relative), encoding: .utf8) }
    func touch(_ marker: String) { FileManager.default.createFile(atPath: url(marker).path, contents: Data()) }

    func modificationDate(_ relative: String) -> Date? {
        (try? url(relative).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    func setDate(_ relative: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url(relative).path)
    }

    func rowCount(_ database: String, _ sql: String) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url(database).path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Lines the stub was invoked with, one per run.
    func stubInvocations() -> [String] {
        ((try? contents(".stub-codex.log")) ?? "").split(separator: "\n").map(String.init)
    }
}

/// Reports fixed holders for any path that matches one of `paths` exactly.
struct FixedOpenHandleChecker: OpenHandleChecker {
    let holders: [OpenHandleHolder]

    func holders(of urls: [URL]) async -> [OpenHandleHolder]? {
        let wanted = Set(urls.map(\.standardizedFileURL.path))
        return holders.filter { wanted.contains($0.path) }
    }
}
