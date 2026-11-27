@testable import DomovyCore
import Foundation
import Testing

/// A throwaway home with VS Code's Roo Code storage copied from `Tests/Fixtures/roo-code/3.x/`
/// (built from Roo Code's source; see the README there). Never the real Application Support.
final class RooCodeFixtureHome: Sendable {
    enum IDs {
        static let parent = "0197a1b2-1111-7111-8111-111111111111"
        /// A subtask of `parent`.
        static let child = "0197a1b2-2222-7222-8222-222222222222"
        static let single = "0197a1b2-3333-7333-8333-333333333333"
    }

    let home: URL
    let storeRoot: URL
    var code: URL { home.appendingPathComponent("Library/Application Support/Code", isDirectory: true) }
    var storage: URL { code.appendingPathComponent("User/globalStorage/rooveterinaryinc.roo-cline", isDirectory: true) }

    init() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("domovy-roo-tests-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        storeRoot = base.appendingPathComponent("store", isDirectory: true)
        try fm.createDirectory(at: code.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: FixtureHome.fixturesRoot.appendingPathComponent("roo-code/3.x/Code", isDirectory: true), to: code)
    }

    deinit {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    func adapter(holders: [OpenHandleHolder] = [], running: [RunningProcess]? = []) -> RooCodeAdapter {
        RooCodeAdapter(home: home, openHandles: FixedOpenHandleChecker(holders: holders), processes: FixedProcessLister(running))
    }

    func executor(running: [RunningProcess]? = []) -> Executor {
        Executor(storeRoot: storeRoot, processes: FixedProcessLister(running))
    }

    func task(_ id: String) -> URL { storage.appendingPathComponent("tasks/\(id)", isDirectory: true).standardizedFileURL }
}

@Suite("Roo Code adapter")
struct RooCodeAdapterTests {
    typealias IDs = RooCodeFixtureHome.IDs

    @Test("lists top-level tasks with title and workspace; subtasks fold into their parent")
    func lists() async throws {
        let fixture = try RooCodeFixtureHome()
        let adapter = fixture.adapter()
        #expect(await adapter.status() == .ready)
        let sessions = try await adapter.sessions()
        #expect(Set(sessions.map(\.id)) == [IDs.parent, IDs.single])
        let parent = try #require(sessions.first { $0.id == IDs.parent })
        #expect(parent.title == "Add retry with backoff to the uploader")
        #expect(parent.projectPath == "/Users/dev/code/orbit-api")
        #expect(parent.origin == nil && parent.agent == .rooCode && parent.status == .idle)
        #expect(parent.sizeBytes > (sessions.first { $0.id == IDs.single }?.sizeBytes ?? 0))
    }

    @Test("artifacts are the task and subtask folders; transcript follows Roo's say messages")
    func artifactsAndTranscript() async throws {
        let fixture = try RooCodeFixtureHome()
        let adapter = fixture.adapter()
        let session = try await adapter.session(matching: IDs.parent)
        #expect(try await adapter.artifacts(of: session).map(\.url) == [fixture.task(IDs.parent), fixture.task(IDs.child)])
        let transcript = try await adapter.transcript(of: session, limit: 10)
        #expect(transcript.messages.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(transcript.messages[2].blocks == [.text("Also log each attempt")])
    }

    @Test("delete plan moves both folders with the editor quit and never touches the index or settings")
    func deletePlan() async throws {
        let fixture = try RooCodeFixtureHome()
        let adapter = fixture.adapter()
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.parent))
        #expect(plan.moves.map(\.source) == [fixture.task(IDs.parent), fixture.task(IDs.child)])
        #expect(plan.mustNotBeRunning.map(\.appName) == ["VS Code"])
        #expect(plan.remarks.contains { $0.contains("subtask") })
        #expect(!plan.liveCheck.isLive)
    }

    @Test("archive compresses the conversation files of the task and its subtask")
    func archivePlan() async throws {
        let fixture = try RooCodeFixtureHome()
        let adapter = fixture.adapter()
        let plan = try await adapter.archivePlan(for: try await adapter.session(matching: IDs.parent))
        #expect(plan.compressions.count == 4)
        #expect(!plan.compressions.contains { $0.file.path.contains("/checkpoints/") })
        let entry = try fixture.executor().execute(plan)
        #expect(try await adapter.sessions().first { $0.id == IDs.parent }?.status == .archived)
        _ = try fixture.executor().undo(entry)
        #expect(try await adapter.sessions().first { $0.id == IDs.parent }?.status == .idle)
    }

    @Test("delete and undo on a temp copy; the index and settings stay")
    func deleteRoundTrip() async throws {
        let fixture = try RooCodeFixtureHome()
        let adapter = fixture.adapter()
        let executor = fixture.executor()
        let entry = try executor.execute(try await adapter.deletePlan(for: try await adapter.session(matching: IDs.parent), destination: .quarantine))
        #expect(!FileSystem.exists(fixture.task(IDs.parent)) && !FileSystem.exists(fixture.task(IDs.child)))
        #expect(FileSystem.exists(fixture.storage.appendingPathComponent("tasks/_index.json")))
        #expect(FileSystem.exists(fixture.storage.appendingPathComponent("settings/mcp_settings.json")))
        #expect(try await adapter.sessions().map(\.id) == [IDs.single])
        _ = try executor.undo(entry)
        #expect(FileSystem.exists(fixture.task(IDs.child).appendingPathComponent("history_item.json")))
    }

    @Test("the editor running, an open file or a write lock refuses")
    func refusesWhileLive() async throws {
        let fixture = try RooCodeFixtureHome()
        let session = try await fixture.adapter().session(matching: IDs.single)
        let running = [RunningProcess(pid: 50, name: "Code")]
        let plan = try await fixture.adapter(running: running).deletePlan(for: session)
        #expect(plan.liveCheck.isLive)
        #expect(throws: ExecutorError.self) { try fixture.executor().execute(plan) }
        let quiet = try await fixture.adapter().deletePlan(for: session)
        #expect(throws: ExecutorError.self) { try fixture.executor(running: running).execute(quiet) }

        let holder = OpenHandleHolder(pid: 51, processName: "Code Helper (Plugin)", path: fixture.task(IDs.single).path)
        #expect(try await fixture.adapter(holders: [holder]).liveCheck(session).isLive)

        try Data().write(to: fixture.task(IDs.single).appendingPathComponent("ui_messages.json.lock"))
        #expect(try await fixture.adapter().sessions().first { $0.id == IDs.single }?.status == .live)
        #expect(try await fixture.adapter().archivePlan(for: session).liveCheck.isLive)
        #expect(FileSystem.exists(fixture.task(IDs.single)))
    }

    @Test("an unknown history_item.json makes Roo Code read-only")
    func unknownLayout() async throws {
        let fixture = try RooCodeFixtureHome()
        try Data(#"{"id":"0197a1b2-3333-7333-8333-333333333333","when":"yesterday"}"#.utf8)
            .write(to: fixture.task(IDs.single).appendingPathComponent("history_item.json"))
        let adapter = fixture.adapter()
        guard case .readOnly = await adapter.status() else { Issue.record("not read-only"); return }
        await #expect(throws: AdapterError.self) { try await adapter.deletePlan(for: try await adapter.session(matching: IDs.parent)) }
    }
}
