@testable import DomovyCore
import Foundation
import Testing

/// OpenCode against a fixture home with the stub CLI. Never the real `opencode`, never `~`.
@Suite("OpenCode adapter")
struct OpenCodeAdapterTests {
    typealias IDs = OpenCodeFixtureHome.IDs

    private func rows(_ fixture: OpenCodeFixtureHome, _ table: String, _ column: String, _ id: String) -> Int {
        SQLiteReader(url: fixture.database)?.count(table: table, column: column, equals: id) ?? -1
    }

    @Test("lists top-level sessions from opencode.db with titles, projects and size estimates")
    func listsSessions() async throws {
        let fixture = try OpenCodeFixtureHome()
        let adapter = fixture.adapter()
        #expect(await adapter.status() == .ready)
        let sessions = try await adapter.sessions()
        #expect(Set(sessions.map(\.id)) == [IDs.idle, IDs.landing, IDs.archived]) // the subagent session is folded in

        let idle = try #require(sessions.first { $0.id == IDs.idle })
        #expect(idle.title == "Add retry to the uploader")
        #expect(idle.projectPath == "/Users/dev/code/orbit-api")
        #expect(idle.agent == .openCode)
        #expect(idle.status == .idle)
        #expect(idle.lastActive == Date(timeIntervalSince1970: 1_795_166_100))
        #expect(idle.transcriptURL == fixture.database)
        let landing = try #require(sessions.first { $0.id == IDs.landing })
        #expect(idle.sizeBytes > landing.sizeBytes) // more rows, a child and a session diff

        let archived = try #require(sessions.first { $0.id == IDs.archived })
        #expect(archived.status == .archived)
        #expect(archived.isArchived)
    }

    @Test("artifacts are rows of the database and the session diff; the database itself never moves")
    func artifacts() async throws {
        let fixture = try OpenCodeFixtureHome()
        let adapter = fixture.adapter()
        let artifacts = try await adapter.artifacts(of: try await adapter.session(matching: IDs.idle))
        #expect(artifacts.contains { $0.kind == .file && $0.url.lastPathComponent == "\(IDs.idle).json" })
        #expect(artifacts.filter { $0.url == fixture.database }.allSatisfy { $0.kind == .indexEntry })
        #expect(artifacts.contains { $0.note.hasPrefix("3 messages in opencode.db") })
        #expect(artifacts.contains { $0.note == "1 subagent session in opencode.db" })
    }

    @Test("transcript shows text and tool parts, not step markers")
    func transcript() async throws {
        let fixture = try OpenCodeFixtureHome()
        let adapter = fixture.adapter()
        let transcript = try await adapter.transcript(of: try await adapter.session(matching: IDs.idle), limit: 50)
        #expect(transcript.messages.map(\.role) == [.user, .assistant])
        #expect(transcript.messages.first?.blocks == [.text("Add retry with backoff to the uploader")])
        #expect(transcript.messages.last?.blocks == [.text("I will wrap the upload call in a retry loop."), .toolCall("edit")])
    }

    @Test("delete runs opencode session delete for the child, then the session, verifies, and undo restores the database")
    func cliDeleteRoundTrip() async throws {
        let fixture = try OpenCodeFixtureHome()
        let adapter = fixture.adapter()
        let session = try await adapter.session(matching: IDs.idle)
        var plan = try await adapter.deletePlan(for: session, destination: .quarantine)
        #expect(plan.commands.map(\.arguments) == [["session", "delete", IDs.child, "--pure"], ["session", "delete", IDs.idle, "--pure"]])
        #expect(plan.commands.allSatisfy { $0.environment["XDG_DATA_HOME"] == fixture.dataFolder.deletingLastPathComponent().path })
        #expect(plan.commands.first?.snapshotsBeforeRun.map(\.lastPathComponent) == ["opencode.db", "opencode.db-wal", "opencode.db-shm"])
        #expect(plan.moves.map(\.source.lastPathComponent) == ["\(IDs.idle).json"])
        #expect(plan.mustNotBeRunning.contains(adapter.processMatcher))
        #expect(plan.acknowledgement == OpenCodeAdapter.acknowledgement)
        #expect(!plan.keepsToolCopies) // no "free the space now": the copy is the whole database

        let executor = fixture.executor()
        #expect(throws: ExecutorError.self) { try executor.execute(plan) } // not acknowledged yet
        #expect(rows(fixture, "session", "id", IDs.idle) == 1)

        plan.isAcknowledged = true
        let entry = try executor.execute(plan)
        #expect(entry.leftovers.isEmpty)
        #expect(rows(fixture, "session", "id", IDs.idle) == 0)
        #expect(rows(fixture, "part", "session_id", IDs.child) == 0)
        #expect(rows(fixture, "session", "id", IDs.landing) == 1) // the others stay
        #expect(!fixture.exists("storage/session_diff/\(IDs.idle).json"))
        #expect(fixture.exists("auth.json"))
        #expect(!entry.snapshots.isEmpty)
        #expect(fixture.stubInvocations().filter { $0.hasPrefix("session delete") } == ["session delete \(IDs.child) --pure", "session delete \(IDs.idle) --pure"])
        #expect(fixture.stubInvocations().first == "session --help") // the probe reads help only
        #expect(try await adapter.sessions().count == 2)

        _ = try executor.undo(entry)
        #expect(rows(fixture, "session", "id", IDs.idle) == 1)
        #expect(rows(fixture, "message", "session_id", IDs.child) == 1)
        #expect(fixture.exists("storage/session_diff/\(IDs.idle).json"))
        #expect(try await adapter.sessions().count == 3)
    }

    @Test("undo refuses once OpenCode wrote to its database again, and says so")
    func undoRefusedAfterChange() async throws {
        let fixture = try OpenCodeFixtureHome()
        let adapter = fixture.adapter()
        var plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.landing), destination: .quarantine)
        plan.isAcknowledged = true
        let executor = fixture.executor()
        let entry = try executor.execute(plan)
        #expect(rows(fixture, "session", "id", IDs.landing) == 0)

        // OpenCode ran again and wrote something: another session goes, through the stub.
        var other = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.archived), destination: .quarantine)
        other.isAcknowledged = true
        _ = try executor.execute(other)
        #expect(throws: ExecutorError.self) { try executor.undo(entry) }
        #expect(rows(fixture, "session", "id", IDs.landing) == 0) // nothing was put back over the newer database
        let logged = try #require(try executor.undoLog.entries().first { $0.id == entry.id })
        #expect(logged.irreversible)
        #expect(logged.notes.contains { $0.contains("can no longer be undone") })
        // Its copy is still there for Purge originals.
        #expect(try executor.purgePlan([.toolCopy]).items.contains { $0.entryID == entry.id })
    }

    @Test("a sloppy opencode leaves rows behind, and the plan reports them")
    func sloppyCLI() async throws {
        let fixture = try OpenCodeFixtureHome()
        fixture.touch(".stub-sloppy")
        let adapter = fixture.adapter()
        var plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.landing), destination: .quarantine)
        plan.isAcknowledged = true
        let entry = try fixture.executor().execute(plan)
        #expect(rows(fixture, "session", "id", IDs.landing) == 0)
        #expect(entry.leftovers.contains { $0.contains("opencode.db (part)") })
        #expect(entry.leftovers.contains { $0.contains("opencode.db (event)") })
    }

    @Test("a failing opencode changes nothing and keeps no copy")
    func failingCLI() async throws {
        let fixture = try OpenCodeFixtureHome()
        fixture.touch(".stub-fail")
        let adapter = fixture.adapter()
        var plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.landing), destination: .quarantine)
        plan.isAcknowledged = true
        let executor = fixture.executor()
        #expect(throws: ExecutorError.self) { try executor.execute(plan) }
        #expect(rows(fixture, "session", "id", IDs.landing) == 1)
        #expect(try executor.undoLog.entries().allSatisfy { $0.snapshots.isEmpty })
    }

    @Test("without the opencode CLI the plan changes nothing and says why")
    func noCLI() async throws {
        let fixture = try OpenCodeFixtureHome()
        let adapter = fixture.adapter(cli: ToolChoice.none)
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.idle), destination: .quarantine)
        #expect(plan.isEmpty)
        #expect(plan.remarks.contains { $0.contains("never edits OpenCode's database") })
        #expect(throws: ExecutorError.self) { try fixture.executor().execute(plan) }

        let archive = try await adapter.archivePlan(for: try await adapter.session(matching: IDs.idle))
        #expect(archive.isEmpty)
        #expect(archive.summary.contains("no file of this session to compress"))
    }

    @Test("a running OpenCode with the database open makes every session live and blocks delete")
    func liveness() async throws {
        let fixture = try OpenCodeFixtureHome()
        let path = fixture.database.standardizedFileURL.path
        let adapter = fixture.adapter(openHandles: FixedOpenHandleChecker(holders: [OpenHandleHolder(pid: 51, processName: "opencode", path: path)]),
                                      running: [RunningProcess(pid: 51, name: "opencode")], openFiles: [51: [path]])
        let sessions = try await adapter.sessions()
        #expect(sessions.allSatisfy { $0.status == .live })
        var plan = try await adapter.deletePlan(for: sessions[0], destination: .quarantine)
        #expect(plan.liveCheck.reasons.contains { $0.contains("OpenCode is using") })
        plan.isAcknowledged = true
        #expect(throws: ExecutorError.self) { try fixture.executor().execute(plan) }

        // An opencode using another data folder does not block.
        let elsewhere = fixture.adapter(running: [RunningProcess(pid: 52, name: "opencode")], openFiles: [52: ["/Users/someone/.local/share/opencode/opencode.db"]])
        let free = try await elsewhere.deletePlan(for: try await elsewhere.session(matching: IDs.idle), destination: .quarantine)
        #expect(!free.liveCheck.isLive)
    }

    @Test("an unknown schema makes the adapter read-only")
    func unknownSchema() async throws {
        let fixture = try OpenCodeFixtureHome()
        try FileManager.default.removeItem(at: fixture.database)
        try CodexFixtureHome.buildDatabase("CREATE TABLE session (id text, name text);", at: fixture.database)
        let adapter = fixture.adapter()
        guard case .readOnly(let reason) = await adapter.status() else {
            Issue.record("expected read-only")
            return
        }
        #expect(reason.contains("lacks"))
    }

    @Test("footprint splits the database into sessions and the event log, and keeps settings")
    func footprint() async throws {
        let fixture = try OpenCodeFixtureHome()
        let footprint = try await fixture.adapter().footprint()
        let names = footprint.categories.map(\.name)
        #expect(names.contains("Sessions (in opencode.db)"))
        #expect(names.contains("Event log (in opencode.db)"))
        #expect(names.contains("File snapshots"))
        #expect(footprint.categories.first { $0.name == "Logs" }?.disposition == .safe)
        let settings = try #require(footprint.categories.first { $0.name == "Settings and sign-in" })
        #expect(settings.disposition == .keep)
        #expect(settings.items.contains { $0.lastPathComponent == "auth.json" })
        #expect(footprint.categories.first { $0.name == "Event log (in opencode.db)" }?.disposition == .consequences)
        #expect(footprint.categories.allSatisfy { $0.cleanupID == nil })

        let layout = OpenCodeLayout(root: fixture.dataFolder, config: fixture.configFolder)
        for name in ["opencode.db", "opencode.db-wal", "auth.json", "bin/opencode"] { #expect(layout.isProtected(fixture.url(name))) }
        #expect(!layout.isProtected(fixture.url("storage/session_diff/\(IDs.idle).json")))
    }

    @Test("opencode and its npm wrapper are classified, other names are not")
    func processes() {
        func agent(_ name: String, _ arguments: [String] = []) -> AgentKind? {
            ProcessClassifier.agent(of: RawProcess(pid: 500, ppid: 1, uid: 501, name: name, startMicros: 1), arguments: { arguments })
        }
        #expect(agent("opencode") == .openCode)
        #expect(agent("node", ["/opt/homebrew/lib/node_modules/opencode-ai/bin/opencode"]) == .openCode)
        #expect(agent("copilot") == .copilot)
        #expect(agent("node", ["/usr/local/lib/node_modules/@github/copilot/index.js"]) == .copilot)
        #expect(agent("Copilot") == nil)
        #expect(ProcessClassifier.agentHint(path: "/Users/dev/.opencode/bin/opencode") == .openCode)
        #expect(OpenCodeAdapter.processMatcher().matches("opencode"))
    }
}
