@testable import DomovyCore
import Foundation
import Testing

/// A throwaway home with `.qwen` copied from `Tests/Fixtures/qwen/0.28/` (built from Qwen Code's
/// source; see the README there). Never the real `~/.qwen`.
final class QwenFixtureHome: Sendable {
    enum IDs {
        /// Title sidecar, every kind of sidecar, subagents, file history, resources.
        static let idle = "a1a1a1a1-1111-4111-8111-111111111111"
        /// Named by `sessions/4242.json`.
        static let live = "b2b2b2b2-2222-4222-8222-222222222222"
        /// In `chats/archive/`, titled by a `custom_title` record.
        static let archived = "c3c3c3c3-3333-4333-8333-333333333333"
        /// Its writer lock names pid 5151.
        static let locked = "d4d4d4d4-4444-4444-8444-444444444444"
    }

    let home: URL
    let storeRoot: URL
    var qwen: URL { home.appendingPathComponent(".qwen", isDirectory: true) }
    var orbit: URL { qwen.appendingPathComponent("projects/-Users-dev-code-orbit-api", isDirectory: true) }

    init() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("domovy-qwen-tests-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        storeRoot = base.appendingPathComponent("store", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.copyItem(at: FixtureHome.fixturesRoot.appendingPathComponent("qwen/0.28/.qwen", isDirectory: true), to: qwen)
    }

    deinit {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    /// Deterministic: no libproc; pid 4242 runs, 5151 only when asked.
    func adapter(holders: [OpenHandleHolder] = [], running: [RunningProcess]? = [], alive: Set<Int32> = [4242]) -> QwenAdapter {
        QwenAdapter(qwenHome: qwen, openHandles: FixedOpenHandleChecker(holders: holders), processes: FixedProcessLister(running),
                    probe: FixedProcessProbe(running: alive))
    }

    func executor(running: [RunningProcess]? = []) -> Executor {
        Executor(storeRoot: storeRoot, processes: FixedProcessLister(running))
    }

    func url(_ relative: String) -> URL { qwen.appendingPathComponent(relative) }
    func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: url(relative).path) }
}

@Suite("Qwen Code adapter")
struct QwenAdapterTests {
    typealias IDs = QwenFixtureHome.IDs
    let orbitChats = "projects/-Users-dev-code-orbit-api/chats"

    @Test("lists active and archived chats with titles, projects and live state")
    func lists() async throws {
        let fixture = try QwenFixtureHome()
        let adapter = fixture.adapter()
        #expect(await adapter.status() == .ready)
        let sessions = try await adapter.sessions()
        #expect(Set(sessions.map(\.id)) == [IDs.idle, IDs.live, IDs.archived, IDs.locked])
        let idle = try #require(sessions.first { $0.id == IDs.idle })
        #expect(idle.title == "Uploader retries")
        #expect(idle.projectPath == "/Users/dev/code/orbit-api")
        #expect(idle.status == .idle)
        #expect(idle.agent == .qwen)
        let archived = try #require(sessions.first { $0.id == IDs.archived })
        #expect(archived.status == .archived && archived.isArchived)
        #expect(archived.title == "Footer rework")
        #expect(sessions.first { $0.id == IDs.live }?.status == .live)
        #expect(sessions.first { $0.id == IDs.live }?.title == "Make the hero image lazy load")
        #expect(sessions.first { $0.id == IDs.locked }?.status == .idle) // the lock's pid is gone: stale
        #expect(try await fixture.adapter(alive: [4242, 5151]).sessions().first { $0.id == IDs.locked }?.status == .live)
    }

    @Test("artifacts are the transcript, every sidecar, subagents, file history and resources; memory stays out")
    func artifacts() async throws {
        let fixture = try QwenFixtureHome()
        let adapter = fixture.adapter()
        let artifacts = try await adapter.artifacts(of: try await adapter.session(matching: IDs.idle))
        let names = artifacts.map(\.url.lastPathComponent)
        #expect(names == ["\(IDs.idle).jsonl", "\(IDs.idle).title.json", "\(IDs.idle).pr.json", "\(IDs.idle).ledger.jsonl",
                          "\(IDs.idle).runtime.json", IDs.idle, IDs.idle, IDs.idle])
        #expect(artifacts.map(\.note).suffix(3) == ["Subagent transcripts", "File history (undo of edits)", "Session resources"])
        #expect(!artifacts.contains { $0.url.path.contains("/memory") || $0.url.lastPathComponent.hasPrefix("session-organization") })
    }

    @Test("transcript reads prompts and model parts with tool calls")
    func transcript() async throws {
        let fixture = try QwenFixtureHome()
        let adapter = fixture.adapter()
        let transcript = try await adapter.transcript(of: try await adapter.session(matching: IDs.idle), limit: 10)
        #expect(transcript.messages.map(\.role) == [.user, .assistant])
        #expect(transcript.messages[1].blocks == [.text("I will start with the retry loop."), .toolCall("read_file")])
    }

    @Test("delete plan moves every file of the session, needs Qwen quit, and leaves the organization file")
    func deletePlan() async throws {
        let fixture = try QwenFixtureHome()
        let adapter = fixture.adapter()
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.idle), destination: .quarantine)
        #expect(plan.moves.count == 8)
        #expect(plan.mustNotBeRunning == [QwenAdapter.processMatcher])
        #expect(plan.remarks.contains { $0.contains("session-organization.v1.json") })
        #expect(!plan.liveCheck.isLive)
    }

    @Test("archive plan renames the transcript and sidecars into chats/archive, not runtime.json")
    func archivePlan() async throws {
        let fixture = try QwenFixtureHome()
        let adapter = fixture.adapter()
        let plan = try await adapter.archivePlan(for: try await adapter.session(matching: IDs.idle))
        #expect(plan.relocations.map(\.source.lastPathComponent) == ["\(IDs.idle).jsonl", "\(IDs.idle).title.json", "\(IDs.idle).pr.json", "\(IDs.idle).ledger.jsonl"])
        #expect(plan.relocations.allSatisfy { $0.target.deletingLastPathComponent().path == fixture.url("\(orbitChats)/archive").standardizedFileURL.path })
        #expect(plan.compressions.isEmpty && plan.moves.isEmpty)
        #expect(plan.summary.contains("into archive/"))
        let already = try await adapter.archivePlan(for: try await adapter.session(matching: IDs.archived))
        #expect(already.isEmpty)
    }

    @Test("archive and undo keep every byte and modification time; Qwen then lists it as archived")
    func archiveRoundTrip() async throws {
        let fixture = try QwenFixtureHome()
        let adapter = fixture.adapter()
        let transcript = fixture.url("\(orbitChats)/\(IDs.idle).jsonl")
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: transcript.path)
        let data = try Data(contentsOf: transcript)
        let executor = fixture.executor()
        let entry = try executor.execute(try await adapter.archivePlan(for: try await adapter.session(matching: IDs.idle)))
        #expect(entry.relocated.count == 4)
        let moved = fixture.url("\(orbitChats)/archive/\(IDs.idle).jsonl")
        #expect(try Data(contentsOf: moved) == data)
        #expect(FileSystem.modificationTime(of: moved)?.seconds == 1_790_000_000)
        #expect(fixture.exists("\(orbitChats)/\(IDs.idle).runtime.json"))
        let archived = try #require(try await adapter.sessions().first { $0.id == IDs.idle })
        #expect(archived.status == .archived)
        #expect(archived.title == "Uploader retries")

        _ = try executor.undo(entry)
        #expect(fixture.exists("\(orbitChats)/\(IDs.idle).jsonl") && !FileManager.default.fileExists(atPath: moved.path))
        #expect(FileSystem.modificationTime(of: transcript)?.seconds == 1_790_000_000)
        #expect(try await adapter.sessions().first { $0.id == IDs.idle }?.status == .idle)
    }

    @Test("delete moves everything to the quarantine and undo puts it back")
    func deleteRoundTrip() async throws {
        let fixture = try QwenFixtureHome()
        let adapter = fixture.adapter()
        let executor = fixture.executor()
        let entry = try executor.execute(try await adapter.deletePlan(for: try await adapter.session(matching: IDs.idle), destination: .quarantine))
        #expect(entry.moved.count == 8)
        #expect(!fixture.exists("\(orbitChats)/\(IDs.idle).jsonl"))
        #expect(!fixture.exists("file-history/\(IDs.idle)"))
        #expect(fixture.exists("projects/-Users-dev-code-orbit-api/session-organization.v1.json"))
        #expect(fixture.exists("projects/-Users-dev-code-orbit-api/memory/notes.md"))
        #expect(try await adapter.sessions().contains { $0.id == IDs.idle } == false)
        _ = try executor.undo(entry)
        #expect(fixture.exists("\(orbitChats)/\(IDs.idle).jsonl") && fixture.exists("resources/\(IDs.idle)/notes.txt"))
    }

    @Test("a live session, an open file or a running Qwen Code refuses")
    func refusesWhileLive() async throws {
        let fixture = try QwenFixtureHome()
        let adapter = fixture.adapter()
        let live = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.live))
        #expect(live.liveCheck.isLive)
        #expect(throws: ExecutorError.self) { try fixture.executor().execute(live) }
        #expect(try await adapter.archivePlan(for: try await adapter.session(matching: IDs.live)).liveCheck.isLive)

        let transcript = fixture.url("\(orbitChats)/\(IDs.idle).jsonl").standardizedFileURL
        let held = fixture.adapter(holders: [OpenHandleHolder(pid: 9, processName: "node", path: transcript.path)])
        #expect(try await held.deletePlan(for: try await adapter.session(matching: IDs.idle)).liveCheck.isLive)

        let running = [RunningProcess(pid: 80, name: "qwen")]
        #expect(try await fixture.adapter(running: running).archivePlan(for: try await adapter.session(matching: IDs.idle)).liveCheck.isLive)
        let quiet = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.idle), destination: .quarantine)
        #expect(throws: ExecutorError.self) { try fixture.executor(running: running).execute(quiet) }
        #expect(fixture.exists("\(orbitChats)/\(IDs.idle).jsonl"))
    }

    @Test("batch plans and live checks match one session at a time")
    func batches() async throws {
        let fixture = try QwenFixtureHome()
        let adapter = fixture.adapter()
        let sessions = try await adapter.sessions()
        let checks = await adapter.liveChecks(for: sessions)
        for (session, check) in zip(sessions, checks) {
            #expect(try check.get().isLive == (try await adapter.liveCheck(session)).isLive)
        }
        let plans = await adapter.deletePlans(for: sessions, destination: .trash)
        #expect(plans.compactMap(\.plan).count == sessions.count)
        #expect(plans.first { $0.session.id == IDs.live }?.plan?.liveCheck.isLive == true)
    }

    @Test("an unknown record layout makes Qwen Code read-only")
    func unknownLayout() async throws {
        let fixture = try QwenFixtureHome()
        try Data(#"{"conversation":"x","role":"user"}"#.utf8).write(to: fixture.url("\(orbitChats)/\(IDs.locked).jsonl"))
        let adapter = fixture.adapter()
        guard case .readOnly = await adapter.status() else { Issue.record("not read-only"); return }
        await #expect(throws: AdapterError.self) { try await adapter.deletePlan(for: try await adapter.session(matching: IDs.idle)) }
        await #expect(throws: AdapterError.self) { try await adapter.archivePlan(for: try await adapter.session(matching: IDs.idle)) }
    }

    @Test("footprint keeps settings and reports the old chat layout")
    func footprint() async throws {
        let fixture = try QwenFixtureHome()
        let footprint = try await fixture.adapter().footprint()
        #expect(footprint.categories.contains { $0.name == "Older chats" && $0.sizeBytes > 0 })
        #expect(footprint.categories.contains { $0.name == "Settings and sign-in" && $0.disposition == .keep })
    }
}
