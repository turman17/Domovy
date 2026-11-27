@testable import DomovyCore
import Foundation
import Testing

/// A throwaway home with `.continue` copied from `Tests/Fixtures/continue/1.x/` (built from Continue's
/// source; see the README there). Never the real `~/.continue`.
final class ContinueFixtureHome: Sendable {
    enum IDs {
        static let listed = "3f1c2b4a-1111-4111-8111-111111111111"
        static let other = "3f1c2b4a-2222-4222-8222-222222222222"
        /// Has a file but no entry in sessions.json.
        static let unlisted = "3f1c2b4a-3333-4333-8333-333333333333"
    }

    let home: URL
    let storeRoot: URL
    var root: URL { home.appendingPathComponent(".continue", isDirectory: true) }
    var list: URL { root.appendingPathComponent("sessions/sessions.json") }

    init() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("domovy-continue-tests-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        storeRoot = base.appendingPathComponent("store", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.copyItem(at: FixtureHome.fixturesRoot.appendingPathComponent("continue/1.x/.continue", isDirectory: true), to: root)
    }

    deinit {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    func adapter(holders: [OpenHandleHolder] = [], running: [RunningProcess]? = []) -> ContinueAdapter {
        ContinueAdapter(continueHome: root, openHandles: FixedOpenHandleChecker(holders: holders), processes: FixedProcessLister(running))
    }

    func executor(running: [RunningProcess]? = []) -> Executor {
        Executor(storeRoot: storeRoot, processes: FixedProcessLister(running))
    }

    func file(_ id: String) -> URL { root.appendingPathComponent("sessions/\(id).json").standardizedFileURL }

    func listedIDs() throws -> [String] {
        let items = try JSONSerialization.jsonObject(with: Data(contentsOf: list)) as? [[String: Any]] ?? []
        return items.compactMap { $0["sessionId"] as? String }
    }
}

@Suite("Continue adapter")
struct ContinueAdapterTests {
    typealias IDs = ContinueFixtureHome.IDs

    @Test("lists session files with titles and workspaces from sessions.json, or from the file")
    func lists() async throws {
        let fixture = try ContinueFixtureHome()
        let adapter = fixture.adapter()
        #expect(await adapter.status() == .ready)
        let sessions = try await adapter.sessions()
        #expect(Set(sessions.map(\.id)) == [IDs.listed, IDs.other, IDs.unlisted])
        let listed = try #require(sessions.first { $0.id == IDs.listed })
        #expect(listed.title == "Uploader retries" && listed.projectPath == "/Users/dev/code/orbit-api" && listed.agent == .continueDev)
        #expect(sessions.first { $0.id == IDs.unlisted }?.title == "Not in the list")
        let transcript = try await adapter.transcript(of: listed, limit: 10)
        #expect(transcript.messages.map(\.role) == [.user, .assistant])
        #expect(transcript.messages[1].blocks.last == .toolCall("read_file"))
        #expect(try await adapter.artifacts(of: listed).map(\.kind) == [.file, .indexEntry])
    }

    @Test("delete plan moves the file and cuts its list entry, with Continue quit everywhere")
    func deletePlan() async throws {
        let fixture = try ContinueFixtureHome()
        let adapter = fixture.adapter()
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.listed))
        #expect(plan.moves.map(\.source) == [fixture.file(IDs.listed)])
        #expect(plan.jsonRemovals.map(\.idField) == ["sessionId"])
        #expect(plan.mustNotBeRunning == ContinueAdapter.matchers)
        #expect(plan.acknowledgement == ContinueAdapter.acknowledgement)
        #expect(!plan.liveCheck.isLive)
        let unlisted = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.unlisted))
        #expect(unlisted.jsonRemovals.isEmpty && unlisted.acknowledgement == nil)
    }

    @Test("delete keeps every other byte of sessions.json and its date; undo restores both")
    func deleteRoundTrip() async throws {
        let fixture = try ContinueFixtureHome()
        let adapter = fixture.adapter()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fixture.list.path)
        let before = try Data(contentsOf: fixture.list)
        var plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.listed), destination: .quarantine)
        plan.isAcknowledged = true
        let executor = fixture.executor()
        let entry = try executor.execute(plan)
        #expect(!FileSystem.exists(fixture.file(IDs.listed)))
        #expect(try fixture.listedIDs() == [IDs.other])
        #expect(FileSystem.modificationTime(of: fixture.list)?.seconds == 1_790_000_000)
        _ = try executor.undo(entry)
        #expect(try Data(contentsOf: fixture.list) == before)
        #expect(FileSystem.exists(fixture.file(IDs.listed)))
    }

    @Test("archive compresses the session file in place")
    func archivePlan() async throws {
        let fixture = try ContinueFixtureHome()
        let adapter = fixture.adapter()
        let plan = try await adapter.archivePlan(for: try await adapter.session(matching: IDs.other))
        #expect(plan.compressions.map(\.file) == [fixture.file(IDs.other)])
        let entry = try fixture.executor().execute(plan)
        #expect(try await adapter.sessions().first { $0.id == IDs.other }?.status == .archived)
        _ = try fixture.executor().undo(entry)
        #expect(try await adapter.sessions().first { $0.id == IDs.other }?.status == .idle)
    }

    @Test("VS Code or cn running, or the file held open, refuses")
    func refusesWhileLive() async throws {
        let fixture = try ContinueFixtureHome()
        let session = try await fixture.adapter().session(matching: IDs.listed)
        for name in ["Code", "cn"] {
            let running = [RunningProcess(pid: 90, name: name)]
            let plan = try await fixture.adapter(running: running).deletePlan(for: session)
            #expect(plan.liveCheck.isLive)
            var quiet = try await fixture.adapter().deletePlan(for: session)
            quiet.isAcknowledged = true
            #expect(throws: ExecutorError.self) { try fixture.executor(running: running).execute(quiet) }
        }
        let holder = OpenHandleHolder(pid: 91, processName: "node", path: fixture.file(IDs.listed).path)
        #expect(try await fixture.adapter(holders: [holder]).liveCheck(session).isLive)
        #expect(try fixture.listedIDs() == [IDs.listed, IDs.other])
    }

    @Test("a sessions.json that is not a list makes Continue read-only")
    func unknownLayout() async throws {
        let fixture = try ContinueFixtureHome()
        try Data(#"{"sessions": []}"#.utf8).write(to: fixture.list)
        let adapter = fixture.adapter()
        guard case .readOnly = await adapter.status() else { Issue.record("not read-only"); return }
        await #expect(throws: AdapterError.self) { try await adapter.deletePlan(for: try await adapter.session(matching: IDs.listed)) }
    }
}
