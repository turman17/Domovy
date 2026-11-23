@testable import DomovyCore
import Foundation
import Testing

/// A throwaway home with `.copilot` copied from `Tests/Fixtures/copilot/assumed/` and its
/// `session-store.db` built from `Tests/Fixtures/copilot/sql/`.
final class CopilotFixtureHome: Sendable {
    enum IDs {
        /// Title and project from `workspace.yaml`; three rows in session-store.db.
        static let migration = "c0c0c0c0-1111-4111-8111-111111111111"
        /// Title from the first user message, project from `session.start`.
        static let footer = "c0c0c0c0-2222-4222-8222-222222222222"
        /// Has `inuse.4242.lock`.
        static let locked = "c0c0c0c0-3333-4333-8333-333333333333"
    }

    let home: URL
    let storeRoot: URL
    var copilotDirectory: URL { home.appendingPathComponent(".copilot", isDirectory: true) }

    init() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("domovy-copilot-tests-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        storeRoot = base.appendingPathComponent("store", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let fixtures = FixtureHome.fixturesRoot.appendingPathComponent("copilot", isDirectory: true)
        try fm.copyItem(at: fixtures.appendingPathComponent("assumed/.copilot", isDirectory: true), to: copilotDirectory)
        let sql = try String(contentsOf: fixtures.appendingPathComponent("sql/session-store.sql"), encoding: .utf8)
        try CodexFixtureHome.buildDatabase(sql, at: copilotDirectory.appendingPathComponent("session-store.db"))
    }

    deinit {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    /// Deterministic: no libproc, nothing running, pid 4242 alive only when asked.
    func adapter(openHandles: any OpenHandleChecker = UnavailableOpenHandleChecker(), running: [RunningProcess]? = [], alive: Set<Int32> = []) -> CopilotAdapter {
        CopilotAdapter(copilotHome: copilotDirectory, openHandles: openHandles, processes: FixedProcessLister(running), probe: FixedProcessProbe(running: alive))
    }

    func executor() -> Executor {
        Executor(storeRoot: storeRoot, processes: FixedProcessLister([]))
    }

    func url(_ relative: String) -> URL { copilotDirectory.appendingPathComponent(relative) }
    func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: url(relative).path) }
}

/// Copilot CLI against a synthetic home built from the documented layout (not installed where
/// Domovy was developed). Never the real `~/.copilot`.
@Suite("Copilot CLI adapter")
struct CopilotAdapterTests {
    typealias IDs = CopilotFixtureHome.IDs

    @Test("lists session folders with titles and projects; folders without events are skipped")
    func listsSessions() async throws {
        let fixture = try CopilotFixtureHome()
        let sessions = try await fixture.adapter().sessions()
        #expect(Set(sessions.map(\.id)) == [IDs.migration, IDs.footer, IDs.locked])

        let migration = try #require(sessions.first { $0.id == IDs.migration })
        #expect(migration.title == "Uploads table migration")
        #expect(migration.projectPath == "/Users/dev/code/orbit-api")
        #expect(migration.agent == .copilot)
        #expect(migration.status == .idle)

        let footer = try #require(sessions.first { $0.id == IDs.footer })
        #expect(footer.title == "Fix the broken link in the footer")
        #expect(footer.projectPath == "/Users/dev/code/landing-site")
        // The lock's pid is not running here, so the session is not live.
        #expect(sessions.first { $0.id == IDs.locked }?.status == .idle)
    }

    @Test("artifacts: the session folder, plus the index rows that name it")
    func artifacts() async throws {
        let fixture = try CopilotFixtureHome()
        let adapter = fixture.adapter()
        let artifacts = try await adapter.artifacts(of: try await adapter.session(matching: IDs.migration))
        #expect(artifacts.first?.kind == .folder)
        #expect(artifacts.first?.url.lastPathComponent == IDs.migration)
        #expect(artifacts.contains { $0.kind == .indexEntry && $0.note.hasPrefix("3 rows in session-store.db") })
        let footer = try await adapter.artifacts(of: try await adapter.session(matching: IDs.footer))
        #expect(footer.count == 1)
    }

    @Test("delete moves the folder, never reindexes, says what stays in session-store.db; undo puts it back")
    func deleteRoundTrip() async throws {
        let fixture = try CopilotFixtureHome()
        let adapter = fixture.adapter()
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.migration), destination: .quarantine)
        #expect(plan.commands.isEmpty)
        #expect(plan.moves.map(\.source.lastPathComponent) == [IDs.migration])
        #expect(plan.remarks.contains { $0.hasPrefix("3 rows in session-store.db still name this session") })
        #expect(plan.remarks.contains { $0.contains("syncs your sessions to your GitHub account") })
        #expect(plan.mustNotBeRunning.contains(CopilotAdapter.processMatcher))

        let store = fixture.url("session-store.db")
        let storeDate = FileSystem.modificationTime(of: store)
        let executor = fixture.executor()
        let entry = try executor.execute(plan)
        #expect(!fixture.exists("session-state/\(IDs.migration)"))
        #expect(fixture.exists("session-state/\(IDs.footer)/events.jsonl"))
        #expect(fixture.exists("config.json"))
        #expect(FileSystem.modificationTime(of: store) == storeDate) // the index is never written
        _ = try executor.undo(entry)
        #expect(fixture.exists("session-state/\(IDs.migration)/workspace.yaml"))
    }

    @Test("a held lock, an open file or a running Copilot CLI blocks; Copilot apps by other names do not")
    func liveness() async throws {
        let fixture = try CopilotFixtureHome()
        let locked = try await fixture.adapter(alive: [4242]).sessions().first { $0.id == IDs.locked }
        #expect(locked?.status == .live)

        let path = fixture.url("session-state/\(IDs.footer)/events.jsonl").standardizedFileURL.path
        let open = fixture.adapter(openHandles: PrefixOpenHandleChecker(holders: [OpenHandleHolder(pid: 77, processName: "node", path: path)]))
        let session = try await open.session(matching: IDs.footer)
        #expect(session.status == .live)
        let plan = try await open.deletePlan(for: session, destination: .quarantine)
        #expect(throws: ExecutorError.self) { try fixture.executor().execute(plan) }
        #expect(fixture.exists("session-state/\(IDs.footer)"))

        let running = fixture.adapter(running: [RunningProcess(pid: 80, name: "copilot")])
        let blocked = try await running.deletePlan(for: try await running.session(matching: IDs.footer), destination: .quarantine)
        #expect(blocked.liveCheck.reasons.contains { $0.contains("Copilot CLI is running") })
        let other = fixture.adapter(running: [RunningProcess(pid: 81, name: "GitHub Copilot for Xcode")])
        let free = try await other.deletePlan(for: try await other.session(matching: IDs.footer), destination: .quarantine)
        #expect(!free.liveCheck.isLive)
    }

    @Test("archive compresses events.jsonl in place and keeps its modification time")
    func archive() async throws {
        let fixture = try CopilotFixtureHome()
        let events = "session-state/\(IDs.footer)/events.jsonl"
        let line = "{\"type\":\"tool.execution_complete\",\"data\":{\"result\":\"synthetic repeated build output for compression\"}}\n"
        let handle = try FileHandle(forWritingTo: fixture.url(events))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(String(repeating: line, count: 2_000).utf8))
        try handle.close()
        let date = Date().addingTimeInterval(-3 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fixture.url(events).path)

        let adapter = fixture.adapter()
        let plan = try await adapter.archivePlan(for: try await adapter.session(matching: IDs.footer))
        #expect(plan.compressions.map(\.file.lastPathComponent) == ["events.jsonl"])
        let entry = try fixture.executor().execute(plan)
        #expect(!entry.compressed.isEmpty)
        #expect(FileSystem.modificationDate(of: fixture.url(events)) == date)
        #expect(try await adapter.session(matching: IDs.footer).status == .archived)
    }

    @Test("transcript reads user and assistant messages; the secret scan covers events.jsonl")
    func transcriptAndSecrets() async throws {
        let fixture = try CopilotFixtureHome()
        let adapter = fixture.adapter()
        let session = try await adapter.session(matching: IDs.migration)
        let transcript = try await adapter.transcript(of: session, limit: 50)
        #expect(transcript.messages.map(\.role) == [.user, .assistant])
        #expect(transcript.messages.last?.blocks.contains(.toolCall("create")) == true)

        let line = "{\"type\":\"user.message\",\"data\":{\"content\":\"use \(SecretSamples.github) for the deploy\"},\"id\":\"e9\"}\n"
        let handle = try FileHandle(forWritingTo: fixture.url("session-state/\(IDs.migration)/events.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        try handle.close()
        let report = try await SecretScanner().scan(session, adapter: adapter)
        #expect(report.findings.count == 1)
        #expect(report.findings.first?.file.lastPathComponent == "events.jsonl")
        let masked = try await adapter.transcript(of: session, limit: 50, masking: report.findings)
        #expect(!masked.messages.contains { $0.blocks.contains(.text("use \(SecretSamples.github) for the deploy")) })
    }

    @Test("footprint keeps settings and the search index, marks logs safe; protected files are never planned")
    func footprint() async throws {
        let fixture = try CopilotFixtureHome()
        let footprint = try await fixture.adapter().footprint()
        let byName = Dictionary(uniqueKeysWithValues: footprint.categories.map { ($0.name, $0) })
        #expect(byName["Settings, agents, skills"]?.disposition == .keep)
        #expect(byName["Search index"]?.disposition == .keep)
        #expect(byName["Sessions"]?.disposition == .consequences)
        #expect(byName["Logs"]?.disposition == .safe)
        #expect(footprint.totalBytes <= DiskUsage.measure(fixture.copilotDirectory).allocated)

        let layout = CopilotLayout(root: fixture.copilotDirectory)
        for name in ["config.json", "mcp-config.json", "session-store.db", "agents/reviewer.agent.md"] { #expect(layout.isProtected(fixture.url(name))) }
        #expect(!layout.isProtected(fixture.url("session-state/\(IDs.migration)")))
    }
}
