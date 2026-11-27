@testable import DomovyCore
import Foundation
import Testing

/// A throwaway home with one Crush project: `<home>/code/orbit-api/.crush/crush.db` built from
/// `Tests/Fixtures/crush/sql/`, listed in `.local/share/crush/projects.json`, and the stub CLI.
final class CrushFixtureHome: Sendable {
    enum IDs {
        static let parent = "7c1d0a2e-1111-4111-8111-111111111111"
        static let title = "title-7c1d0a2e-1111-4111-8111-111111111111"
        static let task = "toolu_01SyntheticTask"
        static let other = "7c1d0a2e-2222-4222-8222-222222222222"
    }

    let home: URL
    let storeRoot: URL
    let stub: URL
    var data: URL { home.appendingPathComponent(".local/share/crush", isDirectory: true) }
    var project: URL { home.appendingPathComponent("code/orbit-api", isDirectory: true) }
    var dataDir: URL { project.appendingPathComponent(".crush", isDirectory: true) }
    var database: URL { dataDir.appendingPathComponent("crush.db") }

    init() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("domovy-crush-tests-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        storeRoot = base.appendingPathComponent("store", isDirectory: true)
        stub = base.appendingPathComponent("bin/crush")
        let fixtures = FixtureHome.fixturesRoot.appendingPathComponent("crush", isDirectory: true)
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try CodexFixtureHome.buildDatabase(String(contentsOf: fixtures.appendingPathComponent("sql/crush.sql"), encoding: .utf8), at: database)
        let projects = ["projects": [["path": project.path, "data_dir": dataDir.path, "last_accessed": "2026-11-20T10:00:00Z"],
                                     ["path": "/nowhere", "data_dir": "/nowhere/.crush", "last_accessed": "2026-01-01T00:00:00Z"]]]
        try JSONSerialization.data(withJSONObject: projects).write(to: data.appendingPathComponent("projects.json"))
        try Data(#"{"providers":{}}"#.utf8).write(to: data.appendingPathComponent("crush.json"))
        try fm.createDirectory(at: stub.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: fixtures.appendingPathComponent("stub-crush.sh"), to: stub)
    }

    deinit {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    func adapter(cli: ToolChoice? = nil, holders: [OpenHandleHolder] = [], running: [RunningProcess]? = [], openFiles: [Int32: [String]] = [:]) -> CrushAdapter {
        CrushAdapter(dataFolder: data, cli: cli ?? .executable(stub), openHandles: FixedOpenHandleChecker(holders: holders),
                     processes: FixedProcessLister(running, openFiles: openFiles))
    }

    func executor(running: [RunningProcess]? = [], openFiles: [Int32: [String]] = [:]) -> Executor {
        Executor(storeRoot: storeRoot, processes: FixedProcessLister(running, openFiles: openFiles))
    }

    func rows(_ table: String, _ column: String, _ id: String) -> Int {
        SQLiteReader(url: database)?.count(table: table, column: column, equals: id) ?? -1
    }

    func stubLog() -> [String] {
        ((try? String(contentsOf: dataDir.appendingPathComponent(".stub-crush.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}

@Suite("Crush adapter")
struct CrushAdapterTests {
    typealias IDs = CrushFixtureHome.IDs

    @Test("lists top-level sessions of each listed project; children fold in; missing projects are skipped")
    func lists() async throws {
        let fixture = try CrushFixtureHome()
        let adapter = fixture.adapter()
        #expect(await adapter.status() == .ready)
        let sessions = try await adapter.sessions()
        #expect(Set(sessions.map(\.id)) == [IDs.parent, IDs.other])
        let parent = try #require(sessions.first { $0.id == IDs.parent })
        #expect(parent.title == "Add retry to the uploader")
        #expect(parent.projectPath == fixture.project.path)
        #expect(parent.transcriptURL == fixture.database.standardizedFileURL)
        #expect(parent.lastActive == Date(timeIntervalSince1970: 1_795_500_600))
        let transcript = try await adapter.transcript(of: parent, limit: 10)
        #expect(transcript.messages.map(\.role) == [.user, .assistant])
        #expect(transcript.messages[1].blocks == [.text("I will wrap the upload in a retry loop."), .toolCall("edit")])
        let artifacts = try await adapter.artifacts(of: parent)
        #expect(artifacts.allSatisfy { $0.kind == .indexEntry && $0.url == fixture.database.standardizedFileURL })
        #expect(artifacts.last?.note.contains("2 child sessions") == true)
    }

    @Test("delete plan runs crush session delete for each child, then the session, against this data dir")
    func deletePlan() async throws {
        let fixture = try CrushFixtureHome()
        let adapter = fixture.adapter()
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.parent))
        #expect(plan.commands.map { $0.arguments[2] } == [IDs.title, IDs.task, IDs.parent])
        let folder = fixture.dataDir.standardizedFileURL.path
        #expect(plan.commands.allSatisfy { $0.arguments == ["session", "delete", $0.arguments[2], "--data-dir", folder, "--cwd", fixture.project.path] })
        #expect(plan.commands[0].snapshotsBeforeRun.map(\.lastPathComponent) == ["crush.db", "crush.db-wal", "crush.db-shm"])
        #expect(plan.acknowledgement == CrushAdapter.acknowledgement)
        #expect(!plan.liveCheck.isLive)
        let archive = try await adapter.archivePlan(for: try await adapter.session(matching: IDs.other))
        #expect(archive.isEmpty)
    }

    @Test("delete runs the stub, rows of the family are gone, the other session stays; undo restores the database")
    func deleteRoundTrip() async throws {
        let fixture = try CrushFixtureHome()
        let adapter = fixture.adapter()
        var plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.parent))
        let executor = fixture.executor()
        #expect(throws: ExecutorError.self) { try executor.execute(plan) } // not acknowledged
        plan.isAcknowledged = true
        let entry = try executor.execute(plan)
        #expect(fixture.stubLog() == ["session delete \(IDs.title)", "session delete \(IDs.task)", "session delete \(IDs.parent)"])
        for id in [IDs.parent, IDs.title, IDs.task] { #expect(fixture.rows("sessions", "id", id) == 0) }
        #expect(fixture.rows("files", "session_id", IDs.parent) == 0)
        #expect(fixture.rows("sessions", "id", IDs.other) == 1)
        #expect(entry.leftovers.isEmpty)
        _ = try executor.undo(entry)
        #expect(fixture.rows("sessions", "id", IDs.parent) == 1)
        #expect(fixture.rows("messages", "session_id", IDs.parent) == 2)
    }

    @Test("crush holding the database open makes the project live and the executor refuses")
    func refusesWhileLive() async throws {
        let fixture = try CrushFixtureHome()
        let database = fixture.database.standardizedFileURL.path
        let holder = OpenHandleHolder(pid: 60, processName: "crush", path: database)
        let held = fixture.adapter(holders: [holder])
        #expect(try await held.sessions().allSatisfy { $0.status == .live })
        let plan = try await held.deletePlan(for: try await held.session(matching: IDs.other))
        #expect(plan.liveCheck.isLive)
        #expect(throws: ExecutorError.self) { try fixture.executor().execute(plan) }

        var quiet = try await fixture.adapter().deletePlan(for: try await fixture.adapter().session(matching: IDs.other))
        quiet.isAcknowledged = true
        let running = [RunningProcess(pid: 60, name: "crush")]
        #expect(throws: ExecutorError.self) { try fixture.executor(running: running, openFiles: [60: [database]]).execute(quiet) }
        #expect(fixture.rows("sessions", "id", IDs.other) == 1)
    }

    @Test("without crush nothing changes; an unknown schema is read-only")
    func withoutCLIAndUnknownLayout() async throws {
        let fixture = try CrushFixtureHome()
        let plan = try await fixture.adapter(cli: ToolChoice.none).deletePlan(for: try await fixture.adapter().session(matching: IDs.other))
        #expect(plan.isEmpty && plan.remarks.first?.contains("crush session delete") == true)
        try CodexFixtureHome.buildDatabase("ALTER TABLE sessions RENAME COLUMN parent_session_id TO parent;", at: fixture.database)
        let adapter = fixture.adapter()
        guard case .readOnly = await adapter.status() else { Issue.record("not read-only"); return }
        await #expect(throws: AdapterError.self) { try await adapter.deletePlan(for: try await adapter.session(matching: IDs.other)) }
    }
}
