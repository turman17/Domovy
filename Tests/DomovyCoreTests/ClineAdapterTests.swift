@testable import DomovyCore
import Foundation
import Testing

/// A throwaway home with `.cline/data` copied from `Tests/Fixtures/cline/3.0/`, `db/sessions.db` built
/// from `Tests/Fixtures/cline/sql/`, and the stub CLI. Never the real `~/.cline`.
final class ClineFixtureHome: Sendable {
    enum IDs {
        static let parent = "sess_01JSYNTHETIC0001"
        /// A sub-agent of `parent`.
        static let child = "sess_01JSYNTHETIC0002"
        /// `running` under pid 4242.
        static let running = "sess_01JSYNTHETIC0003"
    }

    let home: URL
    let storeRoot: URL
    let stub: URL
    var data: URL { home.appendingPathComponent(".cline/data", isDirectory: true) }
    var database: URL { data.appendingPathComponent("db/sessions.db") }

    init() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("domovy-cline-tests-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        storeRoot = base.appendingPathComponent("store", isDirectory: true)
        stub = base.appendingPathComponent("bin/cline")
        let fixtures = FixtureHome.fixturesRoot.appendingPathComponent("cline", isDirectory: true)
        try fm.createDirectory(at: data.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: fixtures.appendingPathComponent("3.0/data", isDirectory: true), to: data)
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sql = try String(contentsOf: fixtures.appendingPathComponent("sql/sessions.sql"), encoding: .utf8)
        try CodexFixtureHome.buildDatabase(sql, at: database)
        for id in [IDs.parent, IDs.running] {
            let path = data.appendingPathComponent("sessions/\(id)/\(id).messages.json").path
            try CodexFixtureHome.buildDatabase("UPDATE sessions SET messages_path = '\(path)' WHERE session_id = '\(id)';", at: database)
        }
        try fm.createDirectory(at: stub.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: fixtures.appendingPathComponent("stub-cline.sh"), to: stub)
    }

    deinit {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    func adapter(cli: ToolChoice? = nil, holders: [OpenHandleHolder] = [], running: [RunningProcess]? = [], alive: Set<Int32> = [4242]) -> ClineAdapter {
        ClineAdapter(dataFolder: data, cli: cli ?? .executable(stub), openHandles: FixedOpenHandleChecker(holders: holders),
                     processes: FixedProcessLister(running), probe: FixedProcessProbe(running: alive))
    }

    func executor(running: [RunningProcess]? = []) -> Executor {
        Executor(storeRoot: storeRoot, processes: FixedProcessLister(running))
    }

    func folder(_ id: String) -> URL { data.appendingPathComponent("sessions/\(id)", isDirectory: true).standardizedFileURL }

    func rows(_ column: String, _ id: String) -> Int {
        SQLiteReader(url: database)?.count(table: "sessions", column: column, equals: id) ?? -1
    }
}

@Suite("Cline adapter")
struct ClineAdapterTests {
    typealias IDs = ClineFixtureHome.IDs

    @Test("lists top-level sessions with titles; a running session whose pid runs is live")
    func lists() async throws {
        let fixture = try ClineFixtureHome()
        let adapter = fixture.adapter()
        #expect(await adapter.status() == .ready)
        let sessions = try await adapter.sessions()
        #expect(Set(sessions.map(\.id)) == [IDs.parent, IDs.running])
        let parent = try #require(sessions.first { $0.id == IDs.parent })
        #expect(parent.title == "Uploader retries" && parent.projectPath == "/Users/dev/code/orbit-api" && parent.status == .idle)
        #expect(sessions.first { $0.id == IDs.running }?.status == .live)
        #expect(sessions.first { $0.id == IDs.running }?.title == "Make the hero image lazy load")
        #expect(try await fixture.adapter(alive: []).sessions().first { $0.id == IDs.running }?.status == .idle)
        let transcript = try await adapter.transcript(of: parent, limit: 10)
        #expect(transcript.messages.map(\.role) == [.user, .assistant])
        #expect(transcript.messages[1].blocks.last == .toolCall("read_file"))
        let artifacts = try await adapter.artifacts(of: parent)
        #expect(artifacts.first?.url == fixture.folder(IDs.parent))
        #expect(artifacts.last?.kind == .indexEntry && artifacts.last?.note.contains("2 rows") == true)
    }

    @Test("delete plan runs cline history delete with copies of the folder and the database")
    func deletePlan() async throws {
        let fixture = try ClineFixtureHome()
        let adapter = fixture.adapter()
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.parent))
        let command = try #require(plan.commands.first)
        #expect(command.arguments == ["history", "delete", "--session-id", IDs.parent])
        #expect(command.environment["CLINE_DATA_DIR"] == fixture.data.standardizedFileURL.path)
        #expect(command.copiesBeforeRun == [fixture.folder(IDs.parent)])
        #expect(command.snapshotsBeforeRun.map(\.lastPathComponent).first == "sessions.db")
        #expect(plan.acknowledgement == ClineAdapter.acknowledgement)
        #expect(plan.remarks.contains { $0.contains("checkpoint refs") })
        #expect(!plan.liveCheck.isLive)
    }

    @Test("archive compresses the session's message files in place")
    func archivePlan() async throws {
        let fixture = try ClineFixtureHome()
        let adapter = fixture.adapter()
        let plan = try await adapter.archivePlan(for: try await adapter.session(matching: IDs.parent))
        #expect(plan.compressions.map(\.file.lastPathComponent) == ["\(IDs.parent).messages.json"])
        let entry = try fixture.executor().execute(plan)
        #expect(try await adapter.sessions().first { $0.id == IDs.parent }?.status == .archived)
        _ = try fixture.executor().undo(entry)
    }

    @Test("delete runs the stub, rows and folder are gone; undo puts both back")
    func deleteRoundTrip() async throws {
        let fixture = try ClineFixtureHome()
        let adapter = fixture.adapter()
        var plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.parent))
        plan.isAcknowledged = true
        let executor = fixture.executor()
        let entry = try executor.execute(plan)
        #expect(fixture.rows("session_id", IDs.parent) == 0 && fixture.rows("session_id", IDs.child) == 0)
        #expect(!FileSystem.exists(fixture.folder(IDs.parent)))
        #expect(fixture.rows("session_id", IDs.running) == 1)
        #expect(entry.leftovers.isEmpty)
        _ = try executor.undo(entry)
        #expect(fixture.rows("session_id", IDs.parent) == 1)
        #expect(FileSystem.exists(fixture.folder(IDs.parent).appendingPathComponent("\(IDs.child).messages.json")))
    }

    @Test("a live session, the database held open or Cline running refuses")
    func refusesWhileLive() async throws {
        let fixture = try ClineFixtureHome()
        let adapter = fixture.adapter()
        let live = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.running))
        #expect(live.liveCheck.isLive)
        #expect(throws: ExecutorError.self) { try fixture.executor().execute(live) }

        let holder = OpenHandleHolder(pid: 61, processName: "Code Helper (Plugin)", path: fixture.database.standardizedFileURL.path)
        #expect(try await fixture.adapter(holders: [holder]).deletePlan(for: try await adapter.session(matching: IDs.parent)).liveCheck.isLive)

        let running = [RunningProcess(pid: 62, name: "cline")]
        #expect(try await fixture.adapter(running: running).deletePlan(for: try await adapter.session(matching: IDs.parent)).liveCheck.isLive)
        var quiet = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.parent))
        quiet.isAcknowledged = true
        #expect(throws: ExecutorError.self) { try fixture.executor(running: running).execute(quiet) }
        #expect(fixture.rows("session_id", IDs.parent) == 1)
    }

    @Test("without cline nothing changes; an unknown schema is read-only")
    func withoutCLIAndUnknownLayout() async throws {
        let fixture = try ClineFixtureHome()
        let plan = try await fixture.adapter(cli: ToolChoice.none).deletePlan(for: try await fixture.adapter().session(matching: IDs.parent))
        #expect(plan.isEmpty && plan.remarks.first?.contains("cline history delete") == true)
        try CodexFixtureHome.buildDatabase("ALTER TABLE sessions RENAME COLUMN metadata_json TO meta;", at: fixture.database)
        let adapter = fixture.adapter()
        guard case .readOnly = await adapter.status() else { Issue.record("not read-only"); return }
        await #expect(throws: AdapterError.self) { try await adapter.deletePlan(for: try await adapter.session(matching: IDs.parent)) }
    }
}
