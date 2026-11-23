@testable import DomovyCore
import Foundation
import Testing

/// Gemini CLI against a fixture home with the stub CLI. Never the real `gemini`, never `~`.
@Suite("Gemini CLI adapter")
struct GeminiAdapterTests {
    typealias IDs = GeminiFixtureHome.IDs

    @Test("lists chats with titles, projects, shared a2a ids and retention")
    func listsSessions() async throws {
        let fixture = try GeminiFixtureHome()
        let sessions = try await fixture.adapter().sessions()
        #expect(sessions.count == 5)

        let idle = try #require(sessions.first { $0.id == IDs.idle })
        #expect(idle.title == "Health check endpoint") // the summary wins over the first prompt
        #expect(idle.projectPath == fixture.project.path)
        #expect(idle.status == .idle)
        #expect(idle.agent == .gemini)

        let digit = try #require(sessions.first { $0.id == IDs.digit })
        #expect(digit.title == "Explain the rate limiter")

        // 26 days old with a 30-day maxAge: four days left, inside the 7-day window.
        let old = try #require(sessions.first { $0.id == IDs.old })
        #expect(old.status == .expiring)
        #expect((old.daysUntilExpiryForTests ?? 0) <= 4)

        // Two chats share the a2a server's id; both are listed under their own ids, and both
        // have no messages, so Gemini CLI removes them at its next start.
        let a2a = sessions.filter { $0.id.hasPrefix("a2a-server-") }
        #expect(a2a.count == 2)
        #expect(a2a.contains { $0.id == IDs.a2aFirst })
        #expect(a2a.allSatisfy { $0.status == .expiring && $0.title == "Empty chat (no messages)" && $0.retentionNote != nil })
    }

    @Test("artifacts: chat and everything keyed by its id; a shared id owns only the chat")
    func artifacts() async throws {
        let fixture = try GeminiFixtureHome()
        let adapter = fixture.adapter()
        let idle = try await adapter.session(matching: IDs.idle)
        let notes = try await adapter.artifacts(of: idle).map(\.note)
        #expect(notes.contains("Chat"))
        #expect(notes.contains("Subagent chats"))
        #expect(notes.contains("Activity log"))
        #expect(notes.contains("Tool outputs"))
        #expect(notes.contains("Plans and task trackers"))
        #expect(notes.contains { $0.hasPrefix("1 typed prompt in logs.json") })

        let shared = try await adapter.session(matching: IDs.a2aFirst)
        let files = try await adapter.artifacts(of: shared)
        #expect(files.map(\.url.lastPathComponent) == ["session-2026-11-18T07-44-a2a-serv.jsonl"])
    }

    @Test("delete runs gemini --delete-session in the project, verifies, and undo restores")
    func cliDeleteRoundTrip() async throws {
        let fixture = try GeminiFixtureHome()
        let adapter = fixture.adapter()
        let session = try await adapter.session(matching: IDs.idle)
        let mtime = fixture.modificationDate(GeminiFixtureHome.idleChat)
        let plan = try await adapter.deletePlan(for: session, destination: .quarantine)
        let command = try #require(plan.commands.first)
        #expect(command.arguments == ["--delete-session", IDs.idle])
        #expect(command.workingDirectory?.path == fixture.project.path)
        #expect(command.environment["GEMINI_CLI_HOME"] == fixture.home.path)
        #expect(plan.moves.isEmpty)
        #expect(plan.mustNotBeRunning.contains(GeminiAdapter.processMatcher))

        let executor = fixture.executor()
        let entry = try executor.execute(plan)
        #expect(entry.leftovers.isEmpty)
        #expect(!fixture.exists(GeminiFixtureHome.idleChat))
        #expect(!fixture.exists("tmp/orbit-api/logs/session-\(IDs.idle).jsonl"))
        #expect(!fixture.exists("tmp/orbit-api/\(IDs.idle)"))
        #expect(fixture.exists(GeminiFixtureHome.digitChat)) // the other chats stay
        #expect(fixture.exists("settings.json"))
        #expect(fixture.stubInvocations().contains { $0.hasPrefix("--delete-session \(IDs.idle)") })

        _ = try executor.undo(entry)
        #expect(fixture.exists(GeminiFixtureHome.idleChat))
        #expect(fixture.exists("tmp/orbit-api/chats/\(IDs.idle)/r8k2pq.jsonl"))
        #expect(fixture.exists("tmp/orbit-api/tool-outputs/session-\(IDs.idle)/run_shell_command-1.txt"))
        #expect(fixture.modificationDate(GeminiFixtureHome.idleChat) == mtime)
    }

    @Test("a sloppy gemini leaves files behind, and the plan reports them")
    func sloppyCLI() async throws {
        let fixture = try GeminiFixtureHome()
        fixture.touch(".stub-sloppy")
        let adapter = fixture.adapter()
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.idle), destination: .quarantine)
        let entry = try fixture.executor().execute(plan)
        #expect(!fixture.exists(GeminiFixtureHome.idleChat))
        #expect(entry.leftovers.contains { $0.contains("session-\(IDs.idle).jsonl is still there") })
    }

    @Test("chats Gemini CLI's own cleanup removes on start are reported and come back on undo")
    func collateralSweep() async throws {
        let fixture = try GeminiFixtureHome()
        fixture.touch(".stub-sweep")
        let adapter = fixture.adapter()
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.idle), destination: .quarantine)
        let executor = fixture.executor()
        let entry = try executor.execute(plan)
        #expect(!fixture.exists(GeminiFixtureHome.oldChat))
        #expect(entry.leftovers.contains { $0.contains("Gemini CLI also removed 1 other chats of this project") })
        _ = try executor.undo(entry)
        #expect(fixture.exists(GeminiFixtureHome.oldChat))
    }

    @Test("a failing gemini changes nothing")
    func failingCLI() async throws {
        let fixture = try GeminiFixtureHome()
        fixture.touch(".stub-fail")
        let adapter = fixture.adapter()
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.idle), destination: .quarantine)
        #expect(throws: ExecutorError.self) { try fixture.executor().execute(plan) }
        #expect(fixture.exists(GeminiFixtureHome.idleChat))
    }

    @Test("falls back to moving files where gemini --delete-session could pick the wrong chat")
    func fallbacks() async throws {
        let fixture = try GeminiFixtureHome()
        let adapter = fixture.adapter()

        // An id starting with a digit could be read as a list position.
        let digit = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.digit), destination: .quarantine)
        #expect(digit.commands.isEmpty)
        #expect(digit.moves.map(\.source.lastPathComponent) == ["session-2026-11-21T10-00-7d7d7d7d.jsonl"])
        #expect(digit.remarks.contains { $0.contains("starts with a digit") })

        // Not listed by Gemini CLI (no messages), and the id is shared: only this chat moves.
        let shared = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.a2aFirst), destination: .quarantine)
        #expect(shared.commands.isEmpty)
        #expect(shared.moves.count == 1)
        #expect(shared.remarks.contains { $0.contains("same session id") })
        let entry = try fixture.executor().execute(shared)
        #expect(!fixture.exists(GeminiFixtureHome.a2aChats[0]))
        #expect(fixture.exists(GeminiFixtureHome.a2aChats[1]))
        _ = try fixture.executor().undo(entry)
        #expect(fixture.exists(GeminiFixtureHome.a2aChats[0]))

        // An expired chat in the project: Gemini's own sweep would delete it on start.
        try fixture.setDate(GeminiFixtureHome.oldChat, Date().addingTimeInterval(-40 * 86_400))
        let swept = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.idle), destination: .quarantine)
        #expect(swept.commands.isEmpty)
        #expect(swept.remarks.contains { $0.contains("its own cleanup") })
        #expect(swept.moves.count == 5)
    }

    @Test("without the CLI every file moves to the quarantine, and undo puts it back")
    func fileFallbackRoundTrip() async throws {
        let fixture = try GeminiFixtureHome()
        let adapter = fixture.adapter(cli: ToolChoice.none)
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.idle), destination: .quarantine)
        #expect(plan.commands.isEmpty)
        #expect(Set(plan.moves.map(\.note)) == ["Chat", "Subagent chats", "Activity log", "Tool outputs", "Plans and task trackers"])
        #expect(plan.remarks.contains { $0.contains("logs.json") })
        let executor = fixture.executor()
        let entry = try executor.execute(plan)
        #expect(!fixture.exists(GeminiFixtureHome.idleChat))
        #expect(fixture.exists("tmp/orbit-api/logs.json")) // shared, never edited
        _ = try executor.undo(entry)
        #expect(fixture.exists(GeminiFixtureHome.idleChat))
        #expect(fixture.exists("tmp/orbit-api/\(IDs.idle)/plan.md"))
    }

    @Test("a running Gemini CLI blocks delete; Google's Gemini app does not")
    func runningCLIBlocks() async throws {
        let fixture = try GeminiFixtureHome()
        let node = RunningProcess(pid: 7001, name: "node")
        let blocked = fixture.adapter(running: [node], arguments: [7001: ["/opt/homebrew/bin/node", "/opt/homebrew/lib/node_modules/@google/gemini-cli/bundle/gemini.js"]])
        let plan = try await blocked.deletePlan(for: try await blocked.session(matching: IDs.idle), destination: .quarantine)
        #expect(plan.liveCheck.isLive)
        #expect(plan.liveCheck.reasons.contains { $0.contains("Gemini CLI is running") })

        let app = fixture.adapter(running: [RunningProcess(pid: 7002, name: "Gemini"), RunningProcess(pid: 7003, name: "node")],
                                  arguments: [7003: ["node", "server.js"]])
        let free = try await app.deletePlan(for: try await app.session(matching: IDs.idle), destination: .quarantine)
        #expect(!free.liveCheck.isLive)
    }

    @Test("a chat file held open is live and never planned")
    func openHandleIsLive() async throws {
        let fixture = try GeminiFixtureHome()
        let path = fixture.url(GeminiFixtureHome.idleChat).standardizedFileURL.path
        let adapter = fixture.adapter(openHandles: FixedOpenHandleChecker(holders: [OpenHandleHolder(pid: 42, processName: "node", path: path)]))
        let session = try await adapter.session(matching: IDs.idle)
        #expect(session.status == .live)
        let plan = try await adapter.deletePlan(for: session, destination: .quarantine)
        #expect(throws: ExecutorError.self) { try fixture.executor().execute(plan) }
        #expect(fixture.exists(GeminiFixtureHome.idleChat))
    }

    @Test("archive compresses the chat in place and keeps its modification time")
    func archive() async throws {
        let fixture = try GeminiFixtureHome()
        let chat = fixture.url(GeminiFixtureHome.idleChat)
        let line = "{\"id\":\"bulk\",\"type\":\"info\",\"content\":\"synthetic repeated build output for compression\"}\n"
        let handle = try FileHandle(forWritingTo: chat)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(String(repeating: line, count: 2_000).utf8))
        try handle.close()
        let date = Date().addingTimeInterval(-3 * 86_400)
        try fixture.setDate(GeminiFixtureHome.idleChat, date)

        let adapter = fixture.adapter()
        let plan = try await adapter.archivePlan(for: try await adapter.session(matching: IDs.idle))
        #expect(plan.compressions.map(\.file.lastPathComponent).contains(chat.lastPathComponent))
        let entry = try fixture.executor().execute(plan)
        #expect(!entry.compressed.isEmpty)
        #expect(fixture.modificationDate(GeminiFixtureHome.idleChat) == date)
        let archived = try await adapter.session(matching: IDs.idle)
        #expect(archived.isArchived)
        #expect(archived.status == .archived)
    }

    @Test("retention follows general.sessionRetention")
    func retentionSettings() async throws {
        let fixture = try GeminiFixtureHome()
        try fixture.write("settings.json", #"{"general":{"sessionRetention":{"enabled":true,"maxAge":"2w","maxCount":1}}}"#)
        let adapter = fixture.adapter()
        var sessions = try await adapter.sessions()
        // maxCount 1: only the newest chat with messages of orbit-api is safe.
        #expect(sessions.first { $0.id == IDs.digit }?.status == .idle)
        #expect(sessions.first { $0.id == IDs.idle }?.retentionNote?.contains("newest 1 chats") == true)
        #expect(adapter.retentionRule()?.rule == "Gemini CLI deletes chats older than 2 weeks.")

        try fixture.write("settings.json", #"{"general":{"sessionRetention":{"enabled":false}}}"#)
        sessions = try await adapter.sessions()
        #expect(!sessions.contains { $0.status == .expiring })
        #expect(adapter.retentionRule() == nil)

        #expect(GeminiSettings.parse("30d") == TimeInterval(30 * 86_400))
        #expect(GeminiSettings.parse("1m") == TimeInterval(30 * 86_400))
        #expect(GeminiSettings.parse("0d") == nil)
        #expect(GeminiSettings.parse("30x") == nil)
    }

    @Test("transcript shows user and model messages, not Gemini CLI's notices")
    func transcript() async throws {
        let fixture = try GeminiFixtureHome()
        let adapter = fixture.adapter()
        let transcript = try await adapter.transcript(of: try await adapter.session(matching: IDs.idle), limit: 50)
        #expect(transcript.messages.map(\.role) == [.user, .assistant])
        #expect(transcript.messages.first?.blocks == [.text("Add a health check endpoint to the API")])
    }

    @Test("protected files are never part of a plan, and Antigravity's folders are not Gemini's")
    func protectedAndFootprint() async throws {
        let fixture = try GeminiFixtureHome()
        let layout = GeminiLayout(root: fixture.geminiDirectory)
        for name in ["settings.json", "oauth_creds.json", "projects.json", "antigravity-cli/brain"] {
            #expect(layout.isProtected(fixture.url(name)))
        }
        #expect(!layout.isProtected(fixture.url(GeminiFixtureHome.idleChat)))

        try FileManager.default.createDirectory(at: fixture.url("antigravity-cli/brain"), withIntermediateDirectories: true)
        let footprint = try await fixture.adapter().footprint()
        let names = footprint.categories.map(\.name)
        #expect(names.contains("Chats"))
        #expect(names.contains("Checkpoints"))
        #expect(names.contains("File snapshot history"))
        #expect(footprint.categories.first { $0.name == "Settings, sign-in, extensions" }?.disposition == .keep)
        #expect(!footprint.categories.flatMap { $0.items + [$0.url] }.contains { $0.path.contains("antigravity") })
        #expect(footprint.categories.allSatisfy { $0.cleanupID == nil })
        // Nothing is counted twice: the rows add up to no more than the folder itself.
        #expect(footprint.totalBytes <= DiskUsage.measure(fixture.geminiDirectory).allocated)
    }

    @Test("the secret scan reads Gemini chats and can redact inside them")
    func secrets() async throws {
        let fixture = try GeminiFixtureHome()
        let line = "{\"id\":\"m9\",\"timestamp\":\"2026-11-20T09:16:00.000Z\",\"type\":\"user\",\"content\":\"use \(SecretSamples.github) for the deploy\"}\n"
        let handle = try FileHandle(forWritingTo: fixture.url(GeminiFixtureHome.idleChat))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        try handle.close()
        let adapter = fixture.adapter()
        let session = try await adapter.session(matching: IDs.idle)
        let report = try await SecretScanner().scan(session, adapter: adapter)
        #expect(report.findings.count == 1)
        let plan = try await RedactionPlanner.plan(for: session, findings: report.findings, adapter: adapter)
        #expect(plan.redactionCount == 1)
    }
}

extension Session {
    var daysUntilExpiryForTests: Int? {
        expiresAt.map { Int(ceil($0.timeIntervalSinceNow / 86_400)) }
    }
}
