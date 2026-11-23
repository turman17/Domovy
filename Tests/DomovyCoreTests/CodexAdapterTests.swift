import DomovyCore
import Foundation
import Testing

@Suite("Codex adapter")
struct CodexAdapterTests {
    typealias IDs = CodexFixtureHome.IDs

    private static let protectedNames = ["auth.json", "config.toml", "rules", "skills", "plugins", "AGENTS.md"]

    @Test("probe recognises the fixture layout")
    func probe() async throws {
        let fixture = try CodexFixtureHome()
        #expect(await fixture.adapter().status() == .ready)
        let missing = CodexAdapter(codexHome: fixture.home.appendingPathComponent("nope"), cli: .none)
        #expect(await missing.status() == .notInstalled)
    }

    @Test("lists rollouts, archived and zstd sessions with titles from the indexes")
    func list() async throws {
        let fixture = try CodexFixtureHome()
        let lock = fixture.url("thread-writer-locks/\(IDs.live).lock").standardizedFileURL.path
        let adapter = fixture.adapter(openHandles: FixedOpenHandleChecker(holders: [OpenHandleHolder(pid: 69_629, processName: "codex", path: lock)]))
        let sessions = try await adapter.sessions()
        #expect(sessions.map(\.id).sorted() == [IDs.idle, IDs.live, IDs.compressed, IDs.archived, IDs.bare].sorted())
        #expect(sessions.allSatisfy { $0.agent == .codex && $0.expiresAt == nil })

        // session_index.jsonl: the latest entry wins over the first prompt.
        let idle = try #require(sessions.first { $0.id == IDs.idle })
        #expect(idle.title == "Add retry budget to the orbit API client")
        #expect(idle.projectPath == "/Users/dev/code/orbit-api")
        #expect(idle.status == .idle)
        #expect(idle.transcriptURL.lastPathComponent.hasSuffix("\(IDs.idle).jsonl"), "the segment is not the primary rollout")

        // Not in the index: the first real prompt, after Codex's injected context.
        let live = try #require(sessions.first { $0.id == IDs.live })
        #expect(live.title == "Tighten the hero layout on small screens")
        #expect(live.projectName == "landing-site")
        #expect(live.status == .live)

        // zstd rollout: never read; title and cwd come from state_5.sqlite.
        let compressed = try #require(sessions.first { $0.id == IDs.compressed })
        #expect(compressed.title == "Migrate cron jobs to the queue")
        #expect(compressed.projectPath == "/Users/dev/code/ledger")

        let bare = try #require(sessions.first { $0.id == IDs.bare })
        #expect(bare.title == nil)
        #expect(bare.projectPath == nil)

        let archived = try #require(sessions.first { $0.id == IDs.archived })
        #expect(archived.status == .archived)
        #expect(archived.isArchived)
        #expect(archived.title == "Write release notes for 2.4")
    }

    @Test("artifacts cover rollout segments, images, index lines and database rows, never protected files")
    func artifacts() async throws {
        let fixture = try CodexFixtureHome()
        let adapter = fixture.adapter()
        let artifacts = try await adapter.artifacts(of: try await adapter.session(matching: IDs.idle))
        let names = Set(artifacts.map { FileSystem_relative($0.url, fixture.codexDirectory) })
        #expect(names == [
            CodexFixtureHome.idleRollout, CodexFixtureHome.idleSegment, "generated_images/\(IDs.idle)",
            "session_index.jsonl", "history.jsonl", "state_5.sqlite", "thread_history_1.sqlite",
        ])
        let state = try #require(artifacts.first { $0.url.lastPathComponent == "state_5.sqlite" })
        #expect(state.kind == .indexEntry)
        #expect(state.note.hasPrefix("3 rows in state_5.sqlite (threads, thread_spawn_edges, thread_attachments)"))
        let index = try #require(artifacts.first { $0.url.lastPathComponent == "session_index.jsonl" })
        #expect(index.note.hasPrefix("2 entries"))
        #expect(!names.contains { name in Self.protectedNames.contains { name.hasPrefix($0) } })
        #expect(!names.contains { $0.hasPrefix("attachments") }, "attachments are not keyed by thread id")
    }

    @Test("delete plan with the CLI runs codex delete and verifies; only companions move")
    func deletePlanCLI() async throws {
        let fixture = try CodexFixtureHome()
        let adapter = fixture.adapter()
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.idle))

        let command = try #require(plan.commands.first)
        #expect(plan.commands.count == 1)
        #expect(command.executable == fixture.stub)
        #expect(command.arguments == ["delete", "--force", IDs.idle])
        #expect(command.environment["CODEX_HOME"] == fixture.codexDirectory.path)
        #expect(Set(command.copiesBeforeRun.map { FileSystem_relative($0, fixture.codexDirectory) }) == [CodexFixtureHome.idleRollout, CodexFixtureHome.idleSegment])
        #expect(command.verifications.contains(.linesGone(file: fixture.url("session_index.jsonl").standardizedFileURL, key: "id", value: IDs.idle)))
        #expect(command.verifications.contains { if case .rowsGone(_, "threads", "id", IDs.idle) = $0 { true } else { false } })
        #expect(plan.moves.map { FileSystem_relative($0.source, fixture.codexDirectory) } == ["generated_images/\(IDs.idle)"])
        #expect(plan.indexEdits.map(\.file.lastPathComponent) == ["history.jsonl"])
        #expect(plan.mustNotBeRunning == [fixture.adapter().processMatcher])
        #expect(!plan.liveCheck.isLive)
        #expect(plan.summary.hasPrefix("Runs `codex delete` for this session, then checks the result."))
    }

    @Test("delete plan without the CLI moves the rollouts, edits session_index.jsonl and says which rows stay")
    func deletePlanFallback() async throws {
        let fixture = try CodexFixtureHome()
        let adapter = fixture.adapter(cli: CodexCLI.Choice.none)
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.idle), destination: .quarantine)
        #expect(plan.commands.isEmpty)
        #expect(Set(plan.moves.map { FileSystem_relative($0.source, fixture.codexDirectory) }) == [
            CodexFixtureHome.idleRollout, CodexFixtureHome.idleSegment, "generated_images/\(IDs.idle)",
        ])
        #expect(Set(plan.indexEdits.map(\.file.lastPathComponent)) == ["session_index.jsonl", "history.jsonl"])
        let remark = try #require(plan.remarks.first)
        #expect(remark.hasPrefix("5 rows stay in state_5.sqlite, thread_history_1.sqlite."))
        for move in plan.moves {
            let relative = FileSystem_relative(move.source, fixture.codexDirectory)
            #expect(!Self.protectedNames.contains { relative.hasPrefix($0) }, "\(relative) must not be planned")
        }
    }

    @Test("archive plan with the CLI runs codex archive and undoes with codex unarchive")
    func archivePlanCLI() async throws {
        let fixture = try CodexFixtureHome()
        let adapter = fixture.adapter()
        let plan = try await adapter.archivePlan(for: try await adapter.session(matching: IDs.idle))
        let command = try #require(plan.commands.first)
        #expect(command.arguments == ["archive", IDs.idle])
        #expect(command.undo.map(\.arguments) == [["unarchive", IDs.idle]])
        #expect(plan.compressions.isEmpty)
        #expect(plan.mustNotBeRunning == [fixture.adapter().processMatcher])

        let archived = try await adapter.archivePlan(for: try await adapter.session(matching: IDs.archived))
        #expect(archived.isEmpty)
        #expect(archived.summary == "This session is already in archived_sessions.")
    }

    @Test("archive plan without the CLI compresses plain rollouts in place and leaves the index alone")
    func archivePlanFallback() async throws {
        let fixture = try CodexFixtureHome()
        let handle = try FileHandle(forWritingTo: fixture.url(CodexFixtureHome.idleRollout))
        try handle.seekToEnd()
        let filler = #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"c","output":"synthetic build output"}}"#
        try handle.write(contentsOf: Data(String(repeating: filler + "\n", count: 400).utf8))
        try handle.close()

        // Codex running does not block an archive that never touches its index.
        let adapter = fixture.adapter(cli: CodexCLI.Choice.none, running: [RunningProcess(pid: 77, name: "codex")])
        let plan = try await adapter.archivePlan(for: try await adapter.session(matching: IDs.idle))
        #expect(plan.commands.isEmpty)
        #expect(plan.compressions.map { FileSystem_relative($0.file, fixture.codexDirectory) } == [CodexFixtureHome.idleRollout])
        #expect(plan.mustNotBeRunning.isEmpty)
        #expect(!plan.liveCheck.isLive)

        let compressed = try await adapter.archivePlan(for: try await adapter.session(matching: IDs.compressed))
        #expect(compressed.compressions.isEmpty, ".zst rollouts gain nothing from APFS compression")
    }

    @Test("a Codex process using this CODEX_HOME blocks every plan that touches its index")
    func runningCodexRefusal() async throws {
        let fixture = try CodexFixtureHome()
        let codex = RunningProcess(pid: 8_383, name: "codex")
        let adapter = fixture.adapter(running: [codex], openFiles: [8_383: [fixture.openStateDatabase]])
        let session = try await adapter.session(matching: IDs.idle)
        for plan in [try await adapter.deletePlan(for: session), try await adapter.archivePlan(for: session)] {
            #expect(plan.liveCheck.isLive)
            #expect(plan.liveCheck.reasons.contains { $0.hasPrefix("Codex is using ") && $0.hasSuffix("(pid 8383). Quit the ChatGPT app or Codex to change this session.") })
            #expect(throws: ExecutorError.self) { try fixture.executor(running: [codex], openFiles: [8_383: [fixture.openStateDatabase]]).execute(plan) }
        }
        let helper = RunningProcess(pid: 1, name: "codex-code-mode")
        let fallback = try await fixture.adapter(cli: CodexCLI.Choice.none, running: [helper], openFiles: [1: [fixture.openStateDatabase]]).deletePlan(for: session)
        #expect(fallback.liveCheck.isLive)
        #expect(fixture.exists(CodexFixtureHome.idleRollout))
    }

    @Test("a Codex daemon serving another CODEX_HOME does not block")
    func otherCodexHomeDoesNotBlock() async throws {
        let fixture = try CodexFixtureHome()
        // The ChatGPT app's app-server keeps the real ~/.codex open, never this fixture.
        let adapter = fixture.adapter(running: [RunningProcess(pid: 8_383, name: "codex")],
                                      openFiles: [8_383: ["/Users/someone/.codex/state_5.sqlite", "/Users/someone/.codex/logs_2.sqlite"]])
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.idle))
        #expect(!plan.liveCheck.isLive)
        #expect(plan.liveCheck.reasons.isEmpty)
        #expect(plan.liveCheck.checkedSignals.contains("Codex processes"))
    }

    @Test("when Codex's open files or the process list cannot be read, plans are refused")
    func uncheckableCodexRefusal() async throws {
        let fixture = try CodexFixtureHome()
        let unreadable = fixture.adapter(running: [RunningProcess(pid: 8_383, name: "codex")], unreadable: [8_383])
        let session = try await unreadable.session(matching: IDs.idle)
        let plan = try await unreadable.deletePlan(for: session)
        #expect(plan.liveCheck.isLive)
        #expect(plan.liveCheck.reasons.contains { $0.hasPrefix("Domovy could not see which files codex (pid 8383) has open") })

        let noList = try await fixture.adapter(running: nil).deletePlan(for: session)
        #expect(noList.liveCheck.isLive)
        #expect(noList.liveCheck.reasons.contains { $0.hasPrefix("Domovy could not check whether Codex is running") })
    }

    @Test("a session Codex holds open is live and its plans are refused")
    func liveSession() async throws {
        let fixture = try CodexFixtureHome()
        let lock = fixture.url("thread-writer-locks/\(IDs.live).lock").standardizedFileURL.path
        let adapter = fixture.adapter(openHandles: FixedOpenHandleChecker(holders: [OpenHandleHolder(pid: 69_629, processName: "codex", path: lock)]))
        let session = try await adapter.session(matching: IDs.live)
        let plan = try await adapter.deletePlan(for: session)
        #expect(plan.liveCheck.isLive)
        #expect(plan.liveCheck.reasons.first?.hasPrefix("Codex has this session open") == true)
    }

    @Test("an unknown layout makes the adapter read-only with a reason")
    func unknownLayout() async throws {
        let fixture = try CodexFixtureHome()
        try Data("{}\n".utf8).write(to: fixture.url("sessions/2026/11/20/rollout-v2-01a1f011-1111-7111-8111-111111111111.jsonl"))
        let adapter = fixture.adapter()
        guard case .readOnly(let reason) = await adapter.status() else {
            Issue.record("expected read-only")
            return
        }
        #expect(reason.contains("1 session file"))
        let session = try await adapter.session(matching: IDs.idle) // listing still works
        await #expect(throws: AdapterError.self) { try await adapter.deletePlan(for: session) }
        await #expect(throws: AdapterError.self) { try await adapter.archivePlan(for: session) }

        let newer = try CodexFixtureHome()
        try FileManager.default.moveItem(at: newer.url("state_5.sqlite"), to: newer.url("state_6.sqlite"))
        guard case .readOnly(let dbReason) = await newer.adapter().status() else {
            Issue.record("expected read-only for an unknown state database")
            return
        }
        #expect(dbReason.contains("state_6.sqlite"))
    }

    @Test("CLI detection reads the help text; fixture homes never get the real CLI")
    func cliDetection() async throws {
        let fixture = try CodexFixtureHome()
        let tool = try #require(fixture.adapter().commandLineTool)
        #expect(tool.supportsDelete && tool.supportsArchive)
        #expect(fixture.stubInvocations() == ["--help"])

        let home = fixture.stub.deletingLastPathComponent().deletingLastPathComponent()
        #expect(CodexCLI.choice(home: home, isCustomHome: true, environment: [:]) == .executable(fixture.stub))
        #expect(CodexCLI.choice(home: fixture.home, isCustomHome: true, environment: [:]) == CodexCLI.Choice.none)
        #expect(CodexCLI.choice(home: fixture.home, isCustomHome: false, environment: [:]) == .automatic)
        #expect(CodexCLI.choice(home: fixture.home, isCustomHome: false, environment: ["DOMOVY_CODEX_CLI": ""]) == CodexCLI.Choice.none)
    }

    @Test("transcript shows prompts, replies and tool calls; zstd rollouts are refused")
    func transcript() async throws {
        let fixture = try CodexFixtureHome()
        let adapter = fixture.adapter()
        let transcript = try await adapter.transcript(of: try await adapter.session(matching: IDs.idle), limit: 50)
        #expect(transcript.messages.map(\.role) == [.user, .assistant, .assistant])
        #expect(transcript.messages.first?.blocks == [.text("Add retries to the orbit API client\nUse exponential backoff.")])
        #expect(transcript.messages[1].blocks == [.toolCall("shell")])
        await #expect(throws: AdapterError.self) {
            try await adapter.transcript(of: try await adapter.session(matching: IDs.compressed), limit: 50)
        }
    }
}
