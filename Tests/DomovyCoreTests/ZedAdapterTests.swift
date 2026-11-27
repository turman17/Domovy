@testable import DomovyCore
import Foundation
import Testing

/// A throwaway home with Zed's two databases built from `Tests/Fixtures/zed/1.29/`. Never the
/// real Zed folder.
final class ZedFixtureHome: Sendable {
    enum IDs {
        static let json = "2ed00001-1111-4111-8111-111111111111"
        static let child = "2ed00003-3333-4333-8333-333333333333"
        static let zstd = "2ed00002-2222-4222-8222-222222222222"
        static let unlisted = "2ed00004-4444-4444-8444-444444444444"
        static let codex = "01a1f011-1111-7111-8111-111111111111"
    }

    let home: URL
    let storeRoot: URL
    var support: URL { ZedLayout.home(home) }
    var threads: URL { support.appendingPathComponent("threads/threads.db") }
    var workspace: URL { support.appendingPathComponent("db/0-stable/db.sqlite") }

    init() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("domovy-zed-tests-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        storeRoot = base.appendingPathComponent("store", isDirectory: true)
        let fixtures = FixtureHome.fixturesRoot.appendingPathComponent("zed/1.29", isDirectory: true)
        try fm.createDirectory(at: threads.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: workspace.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CodexFixtureHome.buildDatabase(String(contentsOf: fixtures.appendingPathComponent("threads.sql"), encoding: .utf8), at: threads)
        try CodexFixtureHome.buildDatabase(String(contentsOf: fixtures.appendingPathComponent("db.sql"), encoding: .utf8), at: workspace)
        try fm.createDirectory(at: support.appendingPathComponent("languages/rust", isDirectory: true), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: support.appendingPathComponent("languages/rust/server"))
    }

    deinit {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    func adapter(running: [RunningProcess]? = [], holders: [OpenHandleHolder] = []) -> ZedAdapter {
        ZedAdapter(supportDirectory: support, openHandles: FixedOpenHandleChecker(holders: holders), processes: FixedProcessLister(running))
    }

    func executor(running: [RunningProcess]? = []) -> Executor {
        Executor(storeRoot: storeRoot, processes: FixedProcessLister(running))
    }

    func count(_ database: URL, _ sql: String) -> Int {
        SQLiteReader(url: database)?.rows(sql).first?.first.flatMap { $0 }.flatMap { Int($0) } ?? -1
    }

    func write(_ database: URL, _ sql: String) throws {
        try CodexFixtureHome.buildDatabase(sql, at: database)
    }
}

@Suite("Zed adapter")
struct ZedAdapterTests {
    typealias IDs = ZedFixtureHome.IDs

    @Test("lists native threads with titles, projects and dates; external agents and drafts stay out")
    func lists() async throws {
        let fixture = try ZedFixtureHome()
        let adapter = fixture.adapter()
        #expect(await adapter.status() == .ready)
        let sessions = try await adapter.sessions()
        #expect(Set(sessions.map(\.id)) == [IDs.json, IDs.zstd, IDs.unlisted])
        let json = try #require(sessions.first { $0.id == IDs.json })
        #expect(json.title == "Fix the flaky upload test")
        #expect(json.projectPath == "/Users/dev/code/orbit-api")
        #expect(abs(json.lastActive.timeIntervalSince1970 - 1_794_520_392.25) < 0.001)
        #expect(json.status == .idle)
        #expect(json.transcriptURL == fixture.threads)
        let zstd = try #require(sessions.first { $0.id == IDs.zstd })
        #expect(zstd.title == "Make the hero image lazy load") // title_override wins
        #expect(zstd.sizeBytes >= 250) // the compressed blob plus its sidebar row
        #expect(sessions.first { $0.id == IDs.unlisted }?.title == "Rename the CLI flags")
    }

    @Test("artifacts name the thread row, its subagent, its sidebar entry and its worktree links")
    func artifacts() async throws {
        let fixture = try ZedFixtureHome()
        let adapter = fixture.adapter()
        let artifacts = try await adapter.artifacts(of: try await adapter.session(matching: IDs.json))
        #expect(artifacts.map(\.url) == [fixture.threads, fixture.threads, fixture.workspace, fixture.workspace])
        #expect(artifacts.allSatisfy { $0.kind == .indexEntry })
        #expect(artifacts[1].note.contains("1 subagent thread"))
    }

    @Test("transcript reads plain and zstd threads; damaged zstd rows say why there is no preview")
    func transcript() async throws {
        let fixture = try ZedFixtureHome()
        let adapter = fixture.adapter()
        let transcript = try await adapter.transcript(of: try await adapter.session(matching: IDs.json), limit: 10)
        #expect(transcript.messages.map(\.role) == [.user, .assistant, .assistant])
        #expect(transcript.messages[1].blocks == [.text("Looking at the retry loop first."), .toolCall("read_file")])
        let compressed = try await adapter.transcript(of: try await adapter.session(matching: IDs.zstd), limit: 10)
        #expect(compressed.messages.map(\.role) == [.user, .assistant, .assistant])
        #expect(compressed.messages[0].blocks == [.text("Make the hero image on the landing page lazy load")])
        #expect(compressed.messages[1].blocks.last == .toolCall("edit_file"))
        // zeroblob rows are not zstd: refused with the decoder's reason, never guessed at.
        do {
            _ = try await adapter.transcript(of: try await adapter.session(matching: IDs.unlisted), limit: 10)
            Issue.record("a damaged row must not produce a transcript")
        } catch let error as AdapterError {
            #expect(error.localizedDescription.contains("damaged"))
        }
    }

    @Test("delete plan names the exact rows in both databases and only orphaned worktree records")
    func deletePlan() async throws {
        let fixture = try ZedFixtureHome()
        let adapter = fixture.adapter()
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.json), destination: .quarantine)
        #expect(plan.databaseEdits.map(\.database) == [fixture.threads, fixture.workspace])
        #expect(plan.databaseEdits[0].rows.map(\.key) == [IDs.json, IDs.child])
        let sidebar = plan.databaseEdits[1].rows
        #expect(sidebar.map(\.table) == ["sidebar_threads", "thread_archived_worktrees", "archived_git_worktrees"])
        #expect(sidebar[0].key == "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1" && sidebar[0].encoding == .hexBlob)
        #expect(sidebar[2].key == "1" && sidebar[2].encoding == .integer) // worktree 2 is shared with another thread
        #expect(plan.mustNotBeRunning == [ZedLayout.appMatcher])
        #expect(plan.acknowledgement == ZedAdapter.acknowledgement)
        #expect(plan.moves.isEmpty)
        #expect(!plan.liveCheck.isLive)
    }

    @Test("archive changes nothing and says why")
    func archivePlan() async throws {
        let fixture = try ZedFixtureHome()
        let adapter = fixture.adapter()
        let plan = try await adapter.archivePlan(for: try await adapter.session(matching: IDs.zstd))
        #expect(plan.isEmpty)
        #expect(plan.remarks == [ZedAdapter.archiveRemark])
        #expect(throws: ExecutorError.self) { try fixture.executor().execute(plan) }
    }

    @Test("delete removes exactly those rows, leaves every other table, and undo restores both databases")
    func deleteRoundTrip() async throws {
        let fixture = try ZedFixtureHome()
        let adapter = fixture.adapter()
        var plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.json), destination: .quarantine)
        let executor = fixture.executor()
        #expect(throws: ExecutorError.self) { try executor.execute(plan) } // not acknowledged
        plan.isAcknowledged = true
        let entry = try executor.execute(plan)

        #expect(fixture.count(fixture.threads, "SELECT count(*) FROM threads") == 2)
        #expect(fixture.count(fixture.threads, "SELECT count(*) FROM threads WHERE id = '\(IDs.zstd)'") == 1)
        #expect(fixture.count(fixture.workspace, "SELECT count(*) FROM sidebar_threads") == 3)
        #expect(fixture.count(fixture.workspace, "SELECT count(*) FROM sidebar_threads WHERE agent_id = 'codex-acp'") == 1)
        #expect(fixture.count(fixture.workspace, "SELECT count(*) FROM thread_archived_worktrees") == 1)
        #expect(fixture.count(fixture.workspace, "SELECT count(*) FROM archived_git_worktrees") == 1)
        #expect(fixture.count(fixture.workspace, "SELECT count(*) FROM kv_store") == 1)
        #expect(fixture.count(fixture.workspace, "SELECT count(*) FROM workspaces") == 1)
        #expect(entry.snapshots.filter { $0.copy != nil }.map(\.original).contains(fixture.threads))
        #expect(entry.snapshots.filter { $0.copy != nil }.map(\.original).contains(fixture.workspace))
        #expect(try await adapter.sessions().contains { $0.id == IDs.json } == false)

        _ = try executor.undo(entry)
        #expect(fixture.count(fixture.threads, "SELECT count(*) FROM threads") == 4)
        #expect(fixture.count(fixture.workspace, "SELECT count(*) FROM sidebar_threads") == 4)
        #expect(fixture.count(fixture.workspace, "SELECT count(*) FROM archived_git_worktrees") == 2)
        #expect(try await adapter.sessions().contains { $0.id == IDs.json })
    }

    @Test("a thread only threads.db knows deletes its one row")
    func unlistedThread() async throws {
        let fixture = try ZedFixtureHome()
        let adapter = fixture.adapter()
        var plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.unlisted))
        #expect(plan.databaseEdits.map(\.database) == [fixture.threads])
        plan.isAcknowledged = true
        _ = try fixture.executor().execute(plan)
        #expect(fixture.count(fixture.threads, "SELECT count(*) FROM threads WHERE id = '\(IDs.unlisted)'") == 0)
    }

    @Test("Zed running makes every thread live and the executor refuses")
    func zedRunning() async throws {
        let fixture = try ZedFixtureHome()
        let running = [RunningProcess(pid: 900, name: "zed")]
        let adapter = fixture.adapter(running: running)
        #expect(try await adapter.sessions().allSatisfy { $0.status == .live })
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.json))
        #expect(plan.liveCheck.isLive)

        var quiet = try await fixture.adapter().deletePlan(for: try await fixture.adapter().session(matching: IDs.json))
        quiet.isAcknowledged = true
        #expect(throws: ExecutorError.self) { try fixture.executor(running: running).execute(quiet) }
        #expect(fixture.count(fixture.threads, "SELECT count(*) FROM threads") == 4)

        let holder = OpenHandleHolder(pid: 77, processName: "sqlite3", path: fixture.workspace.path)
        #expect(try await fixture.adapter(holders: [holder]).deletePlan(for: try await fixture.adapter().session(matching: IDs.json)).liveCheck.isLive)
    }

    @Test("an unknown sidebar layout makes Zed read-only")
    func unknownLayout() async throws {
        let fixture = try ZedFixtureHome()
        try fixture.write(fixture.workspace, "ALTER TABLE sidebar_threads RENAME COLUMN session_id TO conversation;")
        let adapter = fixture.adapter()
        guard case .readOnly = await adapter.status() else { Issue.record("not read-only"); return }
        await #expect(throws: AdapterError.self) { try await adapter.deletePlan(for: try await adapter.session(matching: IDs.unlisted)) }
    }

    @Test("Codex notes threads Zed lists and labels threads by the app that started them")
    func codexCrossReference() async throws {
        let zed = try ZedFixtureHome()
        let codex = try CodexFixtureHome()
        try CodexFixtureHome.buildDatabase("""
            ALTER TABLE threads ADD COLUMN originator TEXT;
            UPDATE threads SET originator = 'zed' WHERE id = '\(IDs.codex)';
            UPDATE threads SET originator = 'codex_vscode' WHERE id = '01a1f044-4444-7444-8444-444444444444';
            """, at: codex.url("state_5.sqlite"))
        let adapter = CodexAdapter(codexHome: codex.codexDirectory, cli: .executable(codex.stub), openHandles: UnavailableOpenHandleChecker(),
                                   processes: FixedProcessLister([]), zedDatabase: zed.workspace)
        let sessions = try await adapter.sessions()
        let started = try #require(sessions.first { $0.id == IDs.codex })
        #expect(started.agentLabel == "Codex \u{00B7} Zed")
        #expect(sessions.first { $0.id == "01a1f044-4444-7444-8444-444444444444" }?.origin == "VS Code")
        #expect(try await adapter.artifacts(of: started).contains { $0.url == zed.workspace })
        let plan = try await adapter.deletePlan(for: started)
        #expect(plan.remarks.contains(CodexAdapter.zedRemark))
        #expect(plan.changedFiles.contains(zed.workspace) == false)
    }

    @Test("footprint links threads to Sessions and keeps the rest")
    func footprint() async throws {
        let fixture = try ZedFixtureHome()
        let footprint = try await fixture.adapter().footprint()
        let threads = try #require(footprint.categories.first { $0.name == "Agent threads" })
        #expect(threads.guidance == .manageInSessions)
        #expect(footprint.categories.first { $0.name == "App data" }?.disposition == .keep)
    }

    @Test("Zed's timestamps parse with six fraction digits and an offset")
    func dates() {
        #expect(ZedIndex.date("2026-11-12T21:53:12.250000+00:00")?.timeIntervalSince1970 == 1_794_520_392.25)
        #expect(ZedIndex.date("2026-11-12T21:53:12Z")?.timeIntervalSince1970 == 1_794_520_392)
    }
}
