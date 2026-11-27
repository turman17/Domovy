@testable import DomovyCore
import Foundation
import Testing

/// Kilo Code through the OpenCode adapter's `.kilo` flavor, against a fixture home with the stub
/// `kilo` (Tests/Fixtures/kilo/README.md). Never the real `kilo`, never `~`.
@Suite("Kilo Code adapter")
struct KiloAdapterTests {
    typealias IDs = OpenCodeFixtureHome.IDs

    private func rows(_ fixture: OpenCodeFixtureHome, _ table: String, _ column: String, _ id: String) -> Int {
        SQLiteReader(url: fixture.database)?.count(table: table, column: column, equals: id) ?? -1
    }

    @Test("lists top-level sessions of kilo.db as Kilo Code sessions")
    func lists() async throws {
        let fixture = try OpenCodeFixtureHome(flavor: .kilo)
        let adapter = fixture.adapter()
        #expect(adapter.kind == .kilo)
        #expect(await adapter.status() == .ready)
        let sessions = try await adapter.sessions()
        #expect(Set(sessions.map(\.id)) == [IDs.idle, IDs.landing, IDs.archived])
        #expect(sessions.allSatisfy { $0.agent == .kilo && $0.transcriptURL == fixture.database })
        #expect(sessions.first { $0.id == IDs.archived }?.status == .archived)
        let transcript = try await adapter.transcript(of: try #require(sessions.first { $0.id == IDs.idle }), limit: 10)
        #expect(transcript.messages.first?.blocks == [.text("Add retry with backoff to the uploader")])
    }

    @Test("artifacts are rows of kilo.db; the database never moves")
    func artifacts() async throws {
        let fixture = try OpenCodeFixtureHome(flavor: .kilo)
        let adapter = fixture.adapter()
        let artifacts = try await adapter.artifacts(of: try await adapter.session(matching: IDs.idle))
        #expect(artifacts.contains { $0.url == fixture.database && $0.kind == .indexEntry && $0.note.contains("kilo.db") })
        #expect(!artifacts.contains { $0.kind != .indexEntry && $0.url == fixture.database })
    }

    @Test("delete plan runs kilo session delete for the child, then the session, pinned to this kilo.db")
    func deletePlan() async throws {
        let fixture = try OpenCodeFixtureHome(flavor: .kilo)
        let adapter = fixture.adapter()
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.idle))
        #expect(plan.commands.map(\.arguments) == [["session", "delete", IDs.child, "--pure"], ["session", "delete", IDs.idle, "--pure"]])
        #expect(plan.commands.allSatisfy { $0.environment["KILO_DB"] == fixture.database.path && $0.executable == fixture.stub })
        #expect(plan.commands[0].snapshotsBeforeRun.map(\.lastPathComponent) == ["kilo.db", "kilo.db-wal", "kilo.db-shm"])
        #expect(plan.mustNotBeRunning.first?.names == ["kilo"])
        #expect(plan.acknowledgement == OpenCodeAdapter.acknowledgement(.kilo))
        #expect(!plan.liveCheck.isLive)
    }

    @Test("archive has nothing to compress and says why")
    func archivePlan() async throws {
        let fixture = try OpenCodeFixtureHome(flavor: .kilo)
        let adapter = fixture.adapter()
        let plan = try await adapter.archivePlan(for: try await adapter.session(matching: IDs.landing))
        #expect(plan.isEmpty)
        #expect(plan.remarks.first?.contains("kilo.db") == true)
    }

    @Test("delete runs the stub, rows are gone, undo puts kilo.db back")
    func deleteRoundTrip() async throws {
        let fixture = try OpenCodeFixtureHome(flavor: .kilo)
        let adapter = fixture.adapter()
        var plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.idle), destination: .quarantine)
        plan.isAcknowledged = true
        let executor = fixture.executor()
        let entry = try executor.execute(plan)
        #expect(fixture.stubInvocations().filter { $0.hasPrefix("session delete") }.count == 2)
        #expect(rows(fixture, "session", "id", IDs.idle) == 0)
        #expect(rows(fixture, "session", "id", IDs.child) == 0)
        #expect(rows(fixture, "message", "session_id", IDs.idle) == 0)
        #expect(rows(fixture, "session", "id", IDs.landing) == 1)
        #expect(entry.leftovers.isEmpty)
        _ = try executor.undo(entry)
        #expect(rows(fixture, "session", "id", IDs.idle) == 1)
        #expect(rows(fixture, "message", "session_id", IDs.idle) == 2)
    }

    @Test("kilo running or holding kilo.db open blocks the delete")
    func refusesWhileLive() async throws {
        let fixture = try OpenCodeFixtureHome(flavor: .kilo)
        // The matcher is scoped to this data folder: kilo blocks while it has a file open there.
        let running = [RunningProcess(pid: 31, name: "kilo")]
        let openFiles: [Int32: [String]] = [31: [fixture.database.path]]
        let plan = try await fixture.adapter(running: running, openFiles: openFiles).deletePlan(for: try await fixture.adapter().session(matching: IDs.idle))
        #expect(plan.liveCheck.isLive)
        #expect(throws: ExecutorError.self) { try fixture.executor().execute(plan) }

        let holder = OpenHandleHolder(pid: 32, processName: "kilo", path: fixture.database.path)
        let held = fixture.adapter(openHandles: FixedOpenHandleChecker(holders: [holder]))
        #expect(try await held.sessions().allSatisfy { $0.status == .live })

        var quiet = try await fixture.adapter().deletePlan(for: try await fixture.adapter().session(matching: IDs.idle))
        quiet.isAcknowledged = true
        let executor = Executor(storeRoot: fixture.storeRoot, processes: FixedProcessLister(running, openFiles: openFiles))
        #expect(throws: ExecutorError.self) { try executor.execute(quiet) }
        #expect(rows(fixture, "session", "id", IDs.idle) == 1)
    }

    @Test("without kilo, the plan changes nothing and says why")
    func withoutCLI() async throws {
        let fixture = try OpenCodeFixtureHome(flavor: .kilo)
        let adapter = fixture.adapter(cli: ToolChoice.none)
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.idle))
        #expect(plan.isEmpty)
        #expect(plan.remarks.first?.contains("kilo session delete") == true)
    }
}
