@testable import DomovyCore
import Foundation
import Testing

/// A throwaway home with `.augment` (Tests/Fixtures/auggie/1.2/) or `.factory`
/// (Tests/Fixtures/factory-droid/0.126/), built from each agent's sources; see the READMEs there.
/// Never the real home.
final class JSONLFixtureHome: Sendable {
    let home: URL
    let storeRoot: URL
    let flavor: JSONLSessionFlavor
    var folder: URL { home.appendingPathComponent(flavor.folder, isDirectory: true) }

    init(_ flavor: JSONLSessionFlavor) throws {
        self.flavor = flavor
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("domovy-jsonl-tests-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        storeRoot = base.appendingPathComponent("store", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let source = flavor.kind == .auggie ? "auggie/1.2/.augment" : "factory-droid/0.126/.factory"
        try fm.copyItem(at: FixtureHome.fixturesRoot.appendingPathComponent(source, isDirectory: true), to: folder)
    }

    deinit {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    func adapter(holders: [OpenHandleHolder] = [], running: [RunningProcess]? = []) -> JSONLSessionAdapter {
        JSONLSessionAdapter(folder: folder, flavor: flavor, openHandles: FixedOpenHandleChecker(holders: holders), processes: FixedProcessLister(running))
    }

    func executor(running: [RunningProcess]? = []) -> Executor {
        Executor(storeRoot: storeRoot, processes: FixedProcessLister(running))
    }

    func file(_ relative: String) -> URL { folder.appendingPathComponent(relative).standardizedFileURL }
}

@Suite("Auggie adapter")
struct AuggieAdapterTests {
    static let named = "a1a1a1a1-1111-4111-8111-111111111111"
    static let prompt = "a1a1a1a1-2222-4222-8222-222222222222"
    static let path = "sessions-v2/--Users-dev-code-orbit-api--/\(named)"

    @Test("lists sessions with their session_info name, cwd and the pasted-images folder")
    func lists() async throws {
        let fixture = try JSONLFixtureHome(.auggie)
        let adapter = fixture.adapter()
        #expect(await adapter.status() == .ready)
        let sessions = try await adapter.sessions()
        #expect(Set(sessions.map(\.id)) == [Self.named, Self.prompt])
        let named = try #require(sessions.first { $0.id == Self.named })
        #expect(named.title == "Uploader retries" && named.projectPath == "/Users/dev/code/orbit-api" && named.status == .idle)
        #expect(sessions.first { $0.id == Self.prompt }?.title == "Rename the hero section")
        #expect(try await adapter.artifacts(of: named).map(\.url) == [fixture.file("\(Self.path).jsonl"), fixture.file("\(Self.path).files")])
        let transcript = try await adapter.transcript(of: named, limit: 10)
        #expect(transcript.messages.map(\.role) == [.user, .assistant])
        #expect(transcript.messages[1].blocks.last == .toolCall("read"))
    }

    @Test("delete moves the transcript and its .files folder; undo puts them back")
    func deleteRoundTrip() async throws {
        let fixture = try JSONLFixtureHome(.auggie)
        let adapter = fixture.adapter()
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: Self.named), destination: .quarantine)
        #expect(plan.moves.map(\.source) == [fixture.file("\(Self.path).jsonl"), fixture.file("\(Self.path).files")])
        #expect(plan.mustNotBeRunning == [JSONLSessionFlavor.auggie.matcher])
        #expect(!plan.liveCheck.isLive)
        let executor = fixture.executor()
        let entry = try executor.execute(plan)
        #expect(!FileSystem.exists(fixture.file("\(Self.path).jsonl")))
        #expect(FileSystem.exists(fixture.file("settings.json")) && FileSystem.exists(fixture.file("session.json")))
        #expect(try await adapter.sessions().map(\.id) == [Self.prompt])
        _ = try executor.undo(entry)
        #expect(FileSystem.exists(fixture.file("\(Self.path).files/paste-1.png")))
        #expect(try await adapter.sessions().count == 2)
    }

    @Test("archive compresses the transcript in place and undo decompresses it")
    func archive() async throws {
        let fixture = try JSONLFixtureHome(.auggie)
        let adapter = fixture.adapter()
        let plan = try await adapter.archivePlan(for: try await adapter.session(matching: Self.named))
        #expect(plan.compressions.map(\.file) == [fixture.file("\(Self.path).jsonl")])
        let entry = try fixture.executor().execute(plan)
        #expect(try await adapter.sessions().first { $0.id == Self.named }?.status == .archived)
        _ = try fixture.executor().undo(entry)
        #expect(try await adapter.sessions().first { $0.id == Self.named }?.status == .idle)
    }

    @Test("an open file or a running Auggie refuses")
    func refusesWhileLive() async throws {
        let fixture = try JSONLFixtureHome(.auggie)
        let session = try await fixture.adapter().session(matching: Self.named)
        let holder = OpenHandleHolder(pid: 7, processName: "node", path: fixture.file("\(Self.path).jsonl").path)
        #expect(try await fixture.adapter(holders: [holder]).liveCheck(session).isLive)
        #expect(try await fixture.adapter(holders: [holder]).deletePlan(for: session).liveCheck.isLive)
        let running = [RunningProcess(pid: 70, name: "auggie")]
        let plan = try await fixture.adapter(running: running).deletePlan(for: session)
        #expect(plan.liveCheck.isLive)
        #expect(throws: ExecutorError.self) { try fixture.executor().execute(plan) }
        let quiet = try await fixture.adapter().deletePlan(for: session)
        #expect(throws: ExecutorError.self) { try fixture.executor(running: running).execute(quiet) }
        #expect(FileSystem.exists(fixture.file("\(Self.path).jsonl")))
    }

    @Test("a newer header version or a foreign first line makes Auggie read-only")
    func layoutGate() async throws {
        let fixture = try JSONLFixtureHome(.auggie)
        let file = fixture.file("sessions-v2/--Users-dev-code-landing-site--/\(Self.prompt).jsonl")
        let original = try Data(contentsOf: file)
        try Data((#"{"type":"session","version":9,"id":"\#(Self.prompt)","cwd":"/x"}"# + "\n").utf8).write(to: file)
        let adapter = fixture.adapter()
        guard case .readOnly = await adapter.status() else { Issue.record("not read-only"); return }
        await #expect(throws: AdapterError.self) { try await adapter.deletePlan(for: try await adapter.session(matching: Self.named)) }
        try (Data(#"{"kind":"other"}"#.utf8) + original).write(to: file)
        guard case .readOnly = await adapter.status() else { Issue.record("not read-only"); return }
        await #expect(throws: AdapterError.self) { try await adapter.archivePlan(for: try await adapter.session(matching: Self.named)) }
    }
}

@Suite("Factory Droid adapter")
struct FactoryDroidAdapterTests {
    static let titled = "fd0fd0fd-1111-4111-8111-111111111111"
    static let untitled = "fd0fd0fd-2222-4222-8222-222222222222"
    static let path = "sessions/-Users-dev-code-orbit-api/\(titled)"

    @Test("lists sessions with the session_start title, else the first prompt")
    func lists() async throws {
        let fixture = try JSONLFixtureHome(.factoryDroid)
        let adapter = fixture.adapter()
        #expect(await adapter.status() == .ready)
        let sessions = try await adapter.sessions()
        #expect(Set(sessions.map(\.id)) == [Self.titled, Self.untitled])
        let titled = try #require(sessions.first { $0.id == Self.titled })
        #expect(titled.title == "Fix the flaky upload test" && titled.projectPath == "/Users/dev/code/orbit-api")
        #expect(sessions.first { $0.id == Self.untitled }?.title == "Add a dark mode toggle")
        #expect(try await adapter.artifacts(of: titled).map(\.url) == [fixture.file("\(Self.path).jsonl"), fixture.file("\(Self.path).settings.json")])
        let transcript = try await adapter.transcript(of: titled, limit: 10)
        #expect(transcript.messages.map(\.role) == [.user, .assistant])
        #expect(transcript.messages[1].blocks.last == .toolCall("Read"))
    }

    @Test("delete moves both files, says the cloud copy stays, and undo puts them back")
    func deleteRoundTrip() async throws {
        let fixture = try JSONLFixtureHome(.factoryDroid)
        let adapter = fixture.adapter()
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: Self.titled), destination: .quarantine)
        #expect(plan.moves.map(\.source) == [fixture.file("\(Self.path).jsonl"), fixture.file("\(Self.path).settings.json")])
        #expect(plan.remarks.contains { $0.contains("cloud") })
        let executor = fixture.executor()
        let entry = try executor.execute(plan)
        #expect(!FileSystem.exists(fixture.file("\(Self.path).settings.json")))
        #expect(FileSystem.exists(fixture.file("settings.json")) && FileSystem.exists(fixture.file("mcp.json")))
        _ = try executor.undo(entry)
        #expect(FileSystem.exists(fixture.file("\(Self.path).jsonl")) && FileSystem.exists(fixture.file("\(Self.path).settings.json")))
    }

    @Test("archive compresses the transcript")
    func archive() async throws {
        let fixture = try JSONLFixtureHome(.factoryDroid)
        let adapter = fixture.adapter()
        let plan = try await adapter.archivePlan(for: try await adapter.session(matching: Self.titled))
        #expect(plan.compressions.map(\.file) == [fixture.file("\(Self.path).jsonl")])
        #expect(plan.mustNotBeRunning == [JSONLSessionFlavor.factoryDroid.matcher])
    }

    @Test("a running droid refuses")
    func refusesWhileLive() async throws {
        let fixture = try JSONLFixtureHome(.factoryDroid)
        let session = try await fixture.adapter().session(matching: Self.titled)
        let plan = try await fixture.adapter(running: [RunningProcess(pid: 70, name: "droid")]).deletePlan(for: session)
        #expect(plan.liveCheck.isLive)
        #expect(throws: ExecutorError.self) { try fixture.executor().execute(plan) }
    }

    @Test("a session file not named after its id makes Droid read-only")
    func layoutGate() async throws {
        let fixture = try JSONLFixtureHome(.factoryDroid)
        let file = fixture.file("sessions/-Users-dev-code-landing-site/\(Self.untitled).jsonl")
        try Data((#"{"type":"session_start","id":"someone-else","cwd":"/x"}"# + "\n").utf8).write(to: file)
        let adapter = fixture.adapter()
        guard case .readOnly = await adapter.status() else { Issue.record("not read-only"); return }
        await #expect(throws: AdapterError.self) { try await adapter.deletePlan(for: try await adapter.session(matching: Self.titled)) }
    }
}
