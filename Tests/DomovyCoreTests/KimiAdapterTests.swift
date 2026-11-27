@testable import DomovyCore
import Foundation
import Testing

/// A throwaway home with `.kimi` copied from `Tests/Fixtures/kimi/1.x/` (built from Kimi CLI's
/// source; see the README there). Never the real `~/.kimi`.
final class KimiFixtureHome: Sendable {
    enum IDs {
        static let titled = "e5e5e5e5-1111-4111-8111-111111111111"
        static let prompt = "e5e5e5e5-2222-4222-8222-222222222222"
        /// `archived: true` in state.json.
        static let flagged = "e5e5e5e5-3333-4333-8333-333333333333"
    }

    static let orbitHash = "dc14f6edcdac41e170a4e0fe29c79cec" // md5("/Users/dev/code/orbit-api")

    let home: URL
    let storeRoot: URL
    var kimi: URL { home.appendingPathComponent(".kimi", isDirectory: true) }

    init() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("domovy-kimi-tests-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        storeRoot = base.appendingPathComponent("store", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.copyItem(at: FixtureHome.fixturesRoot.appendingPathComponent("kimi/1.x/.kimi", isDirectory: true), to: kimi)
    }

    deinit {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    func adapter(holders: [OpenHandleHolder] = [], running: [RunningProcess]? = []) -> KimiAdapter {
        KimiAdapter(kimiHome: kimi, openHandles: FixedOpenHandleChecker(holders: holders), processes: FixedProcessLister(running))
    }

    func executor(running: [RunningProcess]? = []) -> Executor {
        Executor(storeRoot: storeRoot, processes: FixedProcessLister(running))
    }

    func folder(_ id: String) -> URL { kimi.appendingPathComponent("sessions/\(Self.orbitHash)/\(id)", isDirectory: true) }
}

@Suite("Kimi CLI adapter")
struct KimiAdapterTests {
    typealias IDs = KimiFixtureHome.IDs

    @Test("md5 of the work dir matches Kimi's folder name")
    func hashing() {
        #expect(KimiLayout.md5("/Users/dev/code/orbit-api") == KimiFixtureHome.orbitHash)
    }

    @Test("lists session folders with titles, projects from kimi.json and the archive flag")
    func lists() async throws {
        let fixture = try KimiFixtureHome()
        let adapter = fixture.adapter()
        #expect(await adapter.status() == .ready)
        let sessions = try await adapter.sessions()
        #expect(Set(sessions.map(\.id)) == [IDs.titled, IDs.prompt, IDs.flagged]) // the flat legacy file is not a session
        let titled = try #require(sessions.first { $0.id == IDs.titled })
        #expect(titled.title == "Uploader retries")
        #expect(titled.projectPath == "/Users/dev/code/orbit-api")
        #expect(titled.status == .idle)
        #expect(sessions.first { $0.id == IDs.prompt }?.title == "Rename the CLI flags")
        let flagged = try #require(sessions.first { $0.id == IDs.flagged })
        #expect(flagged.status == .archived && flagged.projectPath == "/Users/dev/code/landing-site")
    }

    @Test("artifacts are the session folder; transcript skips Kimi's bookkeeping rows")
    func artifactsAndTranscript() async throws {
        let fixture = try KimiFixtureHome()
        let adapter = fixture.adapter()
        let session = try await adapter.session(matching: IDs.titled)
        #expect(try await adapter.artifacts(of: session).map(\.url) == [fixture.folder(IDs.titled).standardizedFileURL])
        let transcript = try await adapter.transcript(of: session, limit: 10)
        #expect(transcript.messages.map(\.role) == [.user, .assistant])
        #expect(transcript.messages[1].blocks == [.text("I will wrap the call in a retry loop."), .toolCall("ReadFile")])
    }

    @Test("delete plan moves the folder, needs Kimi quit, and mentions kimi.json")
    func deletePlan() async throws {
        let fixture = try KimiFixtureHome()
        let adapter = fixture.adapter()
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.titled))
        #expect(plan.moves.map(\.source) == [fixture.folder(IDs.titled).standardizedFileURL])
        #expect(plan.mustNotBeRunning == [KimiAdapter.processMatcher])
        #expect(plan.remarks.contains { $0.contains("kimi.json") })
        #expect(!plan.liveCheck.isLive)
    }

    @Test("archive plan compresses the context and leaves state.json")
    func archivePlan() async throws {
        let fixture = try KimiFixtureHome()
        let adapter = fixture.adapter()
        let plan = try await adapter.archivePlan(for: try await adapter.session(matching: IDs.titled))
        #expect(plan.compressions.map(\.file.lastPathComponent) == ["context.jsonl"])
        let entry = try fixture.executor().execute(plan)
        #expect(entry.compressed.count == 1)
        #expect(try await adapter.sessions().first { $0.id == IDs.titled }?.status == .archived)
        _ = try fixture.executor().undo(entry)
        #expect(try await adapter.sessions().first { $0.id == IDs.titled }?.status == .idle)
    }

    @Test("delete and undo on a temp copy")
    func deleteRoundTrip() async throws {
        let fixture = try KimiFixtureHome()
        let adapter = fixture.adapter()
        let executor = fixture.executor()
        let entry = try executor.execute(try await adapter.deletePlan(for: try await adapter.session(matching: IDs.titled), destination: .quarantine))
        #expect(!FileSystem.exists(fixture.folder(IDs.titled)))
        #expect(FileSystem.exists(fixture.kimi.appendingPathComponent("kimi.json")))
        #expect(try await adapter.sessions().count == 2)
        _ = try executor.undo(entry)
        #expect(FileSystem.exists(fixture.folder(IDs.titled).appendingPathComponent("subagents/agent-1/meta.json")))
    }

    @Test("an open file or a running Kimi refuses")
    func refusesWhileLive() async throws {
        let fixture = try KimiFixtureHome()
        let session = try await fixture.adapter().session(matching: IDs.titled)
        let running = [RunningProcess(pid: 70, name: "kimi")]
        let plan = try await fixture.adapter(running: running).deletePlan(for: session)
        #expect(plan.liveCheck.isLive)
        #expect(throws: ExecutorError.self) { try fixture.executor().execute(plan) }
        // The live check asks about the whole session folder.
        let folderHolder = OpenHandleHolder(pid: 7, processName: "python3", path: fixture.folder(IDs.titled).standardizedFileURL.path)
        #expect(try await fixture.adapter(holders: [folderHolder]).liveCheck(session).isLive)
        #expect(try await fixture.adapter(holders: [folderHolder]).archivePlan(for: session).liveCheck.isLive)
        let quiet = try await fixture.adapter().deletePlan(for: session)
        #expect(throws: ExecutorError.self) { try fixture.executor(running: running).execute(quiet) }
        #expect(FileSystem.exists(fixture.folder(IDs.titled)))
    }

    @Test("an unknown state.json version makes Kimi read-only")
    func unknownLayout() async throws {
        let fixture = try KimiFixtureHome()
        try Data(#"{"version": 7}"#.utf8).write(to: fixture.folder(IDs.prompt).appendingPathComponent("state.json"))
        let adapter = fixture.adapter()
        guard case .readOnly = await adapter.status() else { Issue.record("not read-only"); return }
        await #expect(throws: AdapterError.self) { try await adapter.deletePlan(for: try await adapter.session(matching: IDs.titled)) }
    }
}
