@testable import DomovyCore
import Foundation
import Testing

/// A throwaway home copied from Tests/Fixtures/aider/0.86/ (built from Aider's source; see the README
/// there): `code/orbit-api` is a project another agent knows, `projects/` a search folder. Never the
/// real home, and never a crawl of it.
final class AiderFixtureHome: Sendable {
    let home: URL
    let storeRoot: URL
    var repo: URL { home.appendingPathComponent("code/orbit-api", isDirectory: true).standardizedFileURL }
    var other: URL { home.appendingPathComponent("projects/landing-site", isDirectory: true).standardizedFileURL }

    init() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("domovy-aider-tests-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        storeRoot = base.appendingPathComponent("store", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        try fm.copyItem(at: FixtureHome.fixturesRoot.appendingPathComponent("aider/0.86", isDirectory: true), to: home)
        try fm.createDirectory(at: repo.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: repo.appendingPathComponent(".git/HEAD"))
        // A folder below the repository, as another agent might name it, plus an unrelated folder.
        try fm.createDirectory(at: repo.appendingPathComponent("src", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("unrelated", isDirectory: true), withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    func adapter(known: [String]? = nil, roots: [URL]? = nil, holders: [OpenHandleHolder] = [], running: [RunningProcess]? = []) -> AiderAdapter {
        let paths = known ?? [repo.appendingPathComponent("src").path, home.appendingPathComponent("unrelated").path]
        let discovery = AiderDiscovery(known: { paths }, searchRoots: roots ?? [home.appendingPathComponent("projects", isDirectory: true)])
        return AiderAdapter(aiderHome: home.appendingPathComponent(".aider", isDirectory: true), discovery: discovery,
                            openHandles: FixedOpenHandleChecker(holders: holders), processes: FixedProcessLister(running))
    }

    func executor(running: [RunningProcess]? = []) -> Executor {
        Executor(storeRoot: storeRoot, processes: FixedProcessLister(running))
    }

    func session(_ folder: URL) async throws -> Session {
        try #require(try await adapter().sessions().first { $0.projectPath == folder.path })
    }
}

@Suite("Aider adapter")
struct AiderAdapterTests {
    @Test("finds histories in known projects (via their git root) and search folders only")
    func lists() async throws {
        let fixture = try AiderFixtureHome()
        let adapter = fixture.adapter()
        #expect(await adapter.status() == .ready)
        let sessions = try await adapter.sessions()
        #expect(Set(sessions.compactMap(\.projectPath)) == [fixture.repo.path, fixture.other.path])
        let repo = try await fixture.session(fixture.repo)
        #expect(repo.title == "Add retries to the uploader")
        #expect(repo.id.hasPrefix("aider-") && SafeID.isSafe(repo.id))
        // Without a known project or search folder, nothing is found.
        #expect(try await fixture.adapter(known: [], roots: []).sessions().isEmpty)
    }

    @Test("artifacts are the history files and the tag cache; the transcript leaves out Aider's own output")
    func artifactsAndTranscript() async throws {
        let fixture = try AiderFixtureHome()
        let adapter = fixture.adapter()
        let session = try await fixture.session(fixture.repo)
        #expect(try await adapter.artifacts(of: session).map(\.url.lastPathComponent) == [".aider.chat.history.md", ".aider.input.history", ".aider.tags.cache.v4"])
        let transcript = try await adapter.transcript(of: session, limit: 10)
        #expect(transcript.messages.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(transcript.messages[0].blocks == [.text("Add retries to the uploader")])
        #expect(transcript.messages.allSatisfy { message in message.blocks.allSatisfy { if case .text(let t) = $0 { !t.contains("Applied edit") } else { true } } })
    }

    @Test("delete moves only Aider's files to the quarantine; undo puts them back")
    func deleteRoundTrip() async throws {
        let fixture = try AiderFixtureHome()
        let adapter = fixture.adapter()
        let plan = try await adapter.deletePlan(for: try await fixture.session(fixture.repo), destination: .quarantine)
        #expect(plan.moves.count == 3 && plan.scope == [fixture.repo])
        #expect(plan.mustNotBeRunning == [AiderAdapter.processMatcher])
        let executor = fixture.executor()
        let entry = try executor.execute(plan)
        #expect(!FileSystem.exists(fixture.repo.appendingPathComponent(".aider.chat.history.md")))
        #expect(FileSystem.exists(fixture.repo.appendingPathComponent("README.md")))
        #expect(FileSystem.exists(fixture.home.appendingPathComponent(".aider/oauth-keys.env")))
        _ = try executor.undo(entry)
        #expect(FileSystem.exists(fixture.repo.appendingPathComponent(".aider.tags.cache.v4/cache.db")))
        #expect(try await adapter.sessions().count == 2)
    }

    @Test("archive compresses the chat history in place")
    func archive() async throws {
        let fixture = try AiderFixtureHome()
        let adapter = fixture.adapter()
        let plan = try await adapter.archivePlan(for: try await fixture.session(fixture.repo))
        #expect(plan.compressions.map(\.file.lastPathComponent) == [".aider.chat.history.md"])
        let entry = try fixture.executor().execute(plan)
        #expect(try await fixture.session(fixture.repo).status == .archived)
        _ = try fixture.executor().undo(entry)
        #expect(try await fixture.session(fixture.repo).status == .idle)
    }

    @Test("an open history or a running Aider refuses")
    func refusesWhileLive() async throws {
        let fixture = try AiderFixtureHome()
        let session = try await fixture.session(fixture.repo)
        let holder = OpenHandleHolder(pid: 9, processName: "python3.12", path: fixture.repo.appendingPathComponent(".aider.chat.history.md").path)
        #expect(try await fixture.adapter(holders: [holder]).liveCheck(session).isLive)
        let running = [RunningProcess(pid: 70, name: "aider")]
        let plan = try await fixture.adapter(running: running).deletePlan(for: session)
        #expect(plan.liveCheck.isLive)
        #expect(throws: ExecutorError.self) { try fixture.executor().execute(plan) }
        let quiet = try await fixture.adapter().deletePlan(for: session)
        #expect(throws: ExecutorError.self) { try fixture.executor(running: running).execute(quiet) }
        #expect(FileSystem.exists(fixture.repo.appendingPathComponent(".aider.chat.history.md")))
    }

    @Test("a history without Aider's run header makes Aider read-only")
    func layoutGate() async throws {
        let fixture = try AiderFixtureHome()
        try Data("Some other tool's notes\n".utf8).write(to: fixture.other.appendingPathComponent(".aider.chat.history.md"))
        let adapter = fixture.adapter()
        guard case .readOnly = await adapter.status() else { Issue.record("not read-only"); return }
        await #expect(throws: AdapterError.self) { try await adapter.deletePlan(for: try await fixture.session(fixture.repo)) }
    }

    @Test("search folders come from DOMOVY_AIDER_ROOTS and the Domovy folder's list")
    func configuredRoots() throws {
        let fixture = try AiderFixtureHome()
        let list = DomovyContext.storeRoot(home: fixture.home).appendingPathComponent("aider-search-roots.txt")
        try FileManager.default.createDirectory(at: list.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("~/projects\nrelative/ignored\n".utf8).write(to: list)
        let discovery = AiderDiscovery.standard(home: fixture.home, others: [], environment: ["DOMOVY_AIDER_ROOTS": "/tmp/a:/tmp/b"])
        #expect(discovery.searchRoots.map(\.path) == ["/tmp/a", "/tmp/b", fixture.home.appendingPathComponent("projects").standardizedFileURL.path])
    }
}
