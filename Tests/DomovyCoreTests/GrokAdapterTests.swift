@testable import DomovyCore
import Foundation
import Testing

/// A throwaway home with `.grok/grok.db` built from Tests/Fixtures/grok/sql/grok.sql (the schema of
/// superagent-ai/grok-cli; see the README there) and the wallet Domovy must never touch.
final class GrokFixtureHome: Sendable {
    static let active = "g1g1g1g1-1111-4111-8111-111111111111"
    static let archived = "g1g1g1g1-2222-4222-8222-222222222222"

    let home: URL
    let storeRoot: URL
    var grok: URL { home.appendingPathComponent(".grok", isDirectory: true) }
    var database: URL { grok.appendingPathComponent("grok.db").standardizedFileURL }
    var wallet: URL { grok.appendingPathComponent("wallet.json") }

    init() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("domovy-grok-tests-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        storeRoot = base.appendingPathComponent("store", isDirectory: true)
        try fm.createDirectory(at: grok, withIntermediateDirectories: true)
        let sql = try String(contentsOf: FixtureHome.fixturesRoot.appendingPathComponent("grok/sql/grok.sql"), encoding: .utf8)
        try CodexFixtureHome.buildDatabase(sql, at: database)
        try Data(#"{"address":"synthetic"}"#.utf8).write(to: wallet)
        try Data("{}".utf8).write(to: grok.appendingPathComponent("user-settings.json"))
    }

    deinit {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    func adapter(holders: [OpenHandleHolder] = [], running: [RunningProcess]? = []) -> GrokAdapter {
        GrokAdapter(grokHome: grok, openHandles: FixedOpenHandleChecker(holders: holders), processes: FixedProcessLister(running))
    }

    func executor(running: [RunningProcess]? = []) -> Executor {
        Executor(storeRoot: storeRoot, processes: FixedProcessLister(running))
    }

    func count(_ table: String, _ column: String, _ value: String) -> Int {
        SQLiteReader(url: database)?.count(table: table, column: column, equals: value) ?? -1
    }
}

@Suite("Grok CLI adapter")
struct GrokAdapterTests {
    typealias Home = GrokFixtureHome

    @Test("lists sessions with workspace paths and the archived status")
    func lists() async throws {
        let fixture = try Home()
        let adapter = fixture.adapter()
        #expect(await adapter.status() == .ready)
        let sessions = try await adapter.sessions()
        #expect(sessions.map(\.id) == [Home.active, Home.archived])
        #expect(sessions[0].title == "Uploader retries" && sessions[0].projectPath == "/Users/dev/code/orbit-api" && sessions[0].status == .idle)
        #expect(sessions[1].status == .archived)
        #expect(try await adapter.artifacts(of: sessions[0]).map(\.kind) == [.indexEntry])
        let transcript = try await adapter.transcript(of: sessions[0], limit: 10)
        #expect(transcript.messages.map(\.role) == [.user, .assistant])
        #expect(transcript.messages[1].blocks == [.text("Reading the uploader."), .toolCall("read_file")])
    }

    @Test("delete removes the session's rows from every table, keeps the other session, and undo restores the database")
    func deleteRoundTrip() async throws {
        let fixture = try Home()
        let adapter = fixture.adapter()
        var plan = try await adapter.deletePlan(for: try await adapter.session(matching: Home.active))
        #expect(plan.databaseEdits.count == 1 && plan.moves.isEmpty)
        #expect(Set(plan.databaseEdits[0].rows.map(\.table)) == ["tool_results", "tool_calls", "usage_events", "compactions", "messages", "sessions"])
        #expect(plan.mustNotBeRunning == [GrokAdapter.processMatcher])
        #expect(throws: ExecutorError.self) { try fixture.executor().execute(plan) } // limited undo must be accepted
        plan.isAcknowledged = true
        let executor = fixture.executor()
        let entry = try executor.execute(plan)
        for (table, column) in [("sessions", "id"), ("messages", "session_id"), ("tool_calls", "session_id"), ("usage_events", "session_id"), ("compactions", "session_id")] {
            #expect(fixture.count(table, column, Home.active) == 0, "\(table)")
        }
        #expect(fixture.count("tool_results", "tool_call_row_id", "1") == 0)
        #expect(fixture.count("tool_results", "tool_call_row_id", "2") == 1)
        #expect(fixture.count("sessions", "id", Home.archived) == 1)
        #expect(FileSystem.exists(fixture.wallet))
        _ = try executor.undo(entry)
        #expect(fixture.count("messages", "session_id", Home.active) == 3)
    }

    @Test("a running Grok or an open grok.db refuses")
    func refusesWhileLive() async throws {
        let fixture = try Home()
        let session = try await fixture.adapter().session(matching: Home.active)
        var plan = try await fixture.adapter(running: [RunningProcess(pid: 70, name: "grok")]).deletePlan(for: session)
        plan.isAcknowledged = true
        #expect(plan.liveCheck.isLive)
        #expect(throws: ExecutorError.self) { try fixture.executor().execute(plan) }
        let holder = OpenHandleHolder(pid: 8, processName: "bun", path: fixture.database.path)
        #expect(try await fixture.adapter(holders: [holder]).liveCheck(session).isLive)
        #expect(fixture.count("sessions", "id", Home.active) == 1)
    }

    @Test("archive changes nothing")
    func archive() async throws {
        let fixture = try Home()
        let adapter = fixture.adapter()
        let plan = try await adapter.archivePlan(for: try await adapter.session(matching: Home.active))
        #expect(plan.moves.isEmpty && plan.compressions.isEmpty && plan.databaseEdits.isEmpty)
    }

    @Test("an unknown schema or a ~/.grok without grok.db is read-only")
    func layoutGate() async throws {
        let fixture = try Home()
        try CodexFixtureHome.buildDatabase("PRAGMA user_version = 7;", at: fixture.database)
        let adapter = fixture.adapter()
        guard case .readOnly = await adapter.status() else { Issue.record("not read-only"); return }
        await #expect(throws: AdapterError.self) { try await adapter.deletePlan(for: try await adapter.session(matching: Home.active)) }
        try FileManager.default.removeItem(at: fixture.database)
        guard case .readOnly = await adapter.status() else { Issue.record("not read-only"); return }
    }
}
