import DomovyCore
import Foundation
import Testing

extension GeminiFixtureHome {
    /// Adds `count` synthetic chats with their own ids to orbit-api, and a logs.json entry for
    /// each, like a project with months of history.
    func addSyntheticChats(_ count: Int) throws {
        var log: [[String: String]] = []
        for index in 0..<count {
            let id = String(format: "f0f0%04x-0000-4000-8000-%012x", index, index)
            let header = #"{"sessionId":"\#(id)","projectHash":"0","startTime":"2026-11-01T10:00:00.000Z","lastUpdated":"2026-11-01T10:05:00.000Z","kind":"main"}"#
            let message = #"{"id":"m1","timestamp":"2026-11-01T10:00:05.000Z","type":"user","content":"Synthetic prompt \#(index)"}"#
            try write("tmp/orbit-api/chats/session-2026-11-01T10-00-\(id.prefix(8)).jsonl", header + "\n" + message + "\n")
            log.append(["sessionId": id, "messageId": "0", "timestamp": "2026-11-01T10:00:05.000Z", "type": "user", "message": "Synthetic prompt"])
        }
        try JSONSerialization.data(withJSONObject: log).write(to: url("tmp/orbit-api/logs.json"))
    }
}

@Suite("Batch plans")
struct BatchPlanTests {
    @Test("a Gemini batch plans exactly like one session at a time")
    func geminiBatchMatchesSingles() async throws {
        let fixture = try GeminiFixtureHome()
        try fixture.addSyntheticChats(300)
        let adapter = fixture.adapter()
        let all = try await adapter.sessions()
        let picked = Array(all.prefix(8)) + all.filter { $0.id == GeminiFixtureHome.IDs.a2aGroup }
        #expect(picked.count == 9)

        let batch = await adapter.deletePlans(for: picked, destination: .trash)
        #expect(batch.map(\.session.id) == picked.map(\.id))
        for (session, planned) in zip(picked, batch) {
            let single = try await adapter.deletePlan(for: session, destination: .trash)
            let plan = try #require(planned.plan)
            #expect(plan.moves == single.moves)
            #expect(plan.remarks == single.remarks)
            #expect(plan.liveCheck == single.liveCheck)
            #expect(plan.mustNotBeRunning == single.mustNotBeRunning)
        }
    }

    @Test("a session that cannot be planned does not stop the batch")
    func failureStaysPerSession() async throws {
        let fixture = try GeminiFixtureHome()
        let adapter = fixture.adapter()
        let sessions = try await adapter.sessions()
        let gone = try #require(sessions.first { $0.id == GeminiFixtureHome.IDs.old })
        try FileManager.default.removeItem(at: fixture.url(GeminiFixtureHome.oldChat))
        let batch = await adapter.deletePlans(for: sessions, destination: .trash)
        #expect(batch.count == sessions.count)
        #expect(batch.first { $0.session.id == gone.id }?.plan == nil)
        #expect(batch.filter { $0.plan != nil }.count == sessions.count - 1)
    }

    @Test("Gemini CLI running blocks every plan of the batch")
    func runningBlocksAll() async throws {
        let fixture = try GeminiFixtureHome()
        let node = RunningProcess(pid: 7001, name: "node")
        let adapter = fixture.adapter(running: [node], arguments: [7001: ["/opt/homebrew/bin/node", "/opt/homebrew/lib/node_modules/@google/gemini-cli/bundle/gemini.js"]])
        let sessions = try await fixture.adapter().sessions()
        let batch = await adapter.deletePlans(for: sessions, destination: .trash)
        #expect(!batch.isEmpty)
        #expect(batch.allSatisfy { $0.plan?.liveCheck.isLive == true })
    }
}

/// Everything a plan says, without its id and creation time.
private func expectSamePlan(_ batch: Plan, _ single: Plan, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(batch.sessionID == single.sessionID, sourceLocation: sourceLocation)
    #expect(batch.action == single.action, sourceLocation: sourceLocation)
    #expect(batch.destination == single.destination, sourceLocation: sourceLocation)
    #expect(batch.moves == single.moves, sourceLocation: sourceLocation)
    #expect(batch.indexEdits == single.indexEdits, sourceLocation: sourceLocation)
    #expect(batch.registryRemovals == single.registryRemovals, sourceLocation: sourceLocation)
    #expect(batch.compressions == single.compressions, sourceLocation: sourceLocation)
    #expect(batch.commands == single.commands, sourceLocation: sourceLocation)
    #expect(batch.remarks == single.remarks, sourceLocation: sourceLocation)
    #expect(batch.mustNotBeRunning == single.mustNotBeRunning, sourceLocation: sourceLocation)
    #expect(batch.liveCheck == single.liveCheck, sourceLocation: sourceLocation)
    #expect(batch.scope == single.scope, sourceLocation: sourceLocation)
}

/// Compares a batch with one call per session: plans and errors alike.
private func expectSameAsSingles(
    _ batch: [PlannedSession], _ sessions: [Session], single: (Session) async throws -> Plan,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    #expect(batch.map(\.session.id) == sessions.map(\.id), sourceLocation: sourceLocation)
    for (session, planned) in zip(sessions, batch) {
        switch (planned.result, await Result { try await single(session) }) {
        case (.success(let plan), .success(let one)): expectSamePlan(plan, one, sourceLocation: sourceLocation)
        case (.failure(let error), .failure(let one)): #expect(error.localizedDescription == one.localizedDescription, sourceLocation: sourceLocation)
        default: Issue.record("\(session.id): the batch and a single plan disagree on success", sourceLocation: sourceLocation)
        }
    }
}

private func expectSameChecks(
    _ batch: [Result<LiveCheckResult, any Error>], _ sessions: [Session], single: (Session) async throws -> LiveCheckResult,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    #expect(batch.count == sessions.count, sourceLocation: sourceLocation)
    for (session, checked) in zip(sessions, batch) {
        switch (checked, await Result { try await single(session) }) {
        case (.success(let check), .success(let one)): #expect(check == one, sourceLocation: sourceLocation)
        case (.failure(let error), .failure(let one)): #expect(error.localizedDescription == one.localizedDescription, sourceLocation: sourceLocation)
        default: Issue.record("\(session.id): the batch and a single check disagree on success", sourceLocation: sourceLocation)
        }
    }
}

extension Result where Failure == any Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}

@Suite("Batch plans: Claude Code and Codex")
struct AgentBatchPlanTests {
    @Test("a Claude Code batch plans, archives and checks exactly like one session at a time")
    func claudeBatchMatchesSingles() async throws {
        let fixture = try FixtureHome()
        try fixture.installDesktop()
        // The fixture has set-aside copies and Desktop entries; a holder on one transcript makes
        // one session live, so a batch has something to mix up.
        let expiring = fixture.transcript(FixtureHome.ClaudeCode.expiring, project: "-Users-dev-code-landing-site")
        let holder = OpenHandleHolder(pid: 4711, processName: "vim", path: expiring.standardizedFileURL.path)
        let adapter = fixture.adapter(openHandles: FixedOpenHandleChecker(holders: [holder]))
        let sessions = try await adapter.sessions()
        #expect(sessions.count >= 4)
        let foreign = Session(id: "not-ours", agent: .claudeCode, title: nil, projectPath: nil, lastActive: Date(), sizeBytes: 0,
                              status: .idle, expiresAt: nil, transcriptURL: URL(fileURLWithPath: "/tmp/elsewhere.jsonl"))
        let picked = sessions + [foreign]

        await expectSameAsSingles(await adapter.deletePlans(for: picked, destination: .quarantine), picked) {
            try await adapter.deletePlan(for: $0, destination: .quarantine)
        }
        await expectSameAsSingles(await adapter.archivePlans(for: picked), picked) { try await adapter.archivePlan(for: $0) }
        await expectSameChecks(await adapter.liveChecks(for: picked), picked) { try await adapter.liveCheck($0) }
        let plans = await adapter.deletePlans(for: sessions, destination: .trash).compactMap(\.plan)
        #expect(plans.count == sessions.count)
        #expect(plans.contains { !$0.registryRemovals.isEmpty }, "the fixture links sessions to Claude Desktop")
        #expect(plans.contains { $0.moves.contains { $0.note == "Set-aside copy of the transcript" } })
        #expect(plans.contains { $0.liveCheck.openHandles == .open })
    }

    @Test("a Codex batch plans, archives and checks exactly like one session at a time, with and without the CLI")
    func codexBatchMatchesSingles() async throws {
        let fixture = try CodexFixtureHome()
        let rollout = fixture.url(CodexFixtureHome.idleSegment).standardizedFileURL.path
        let checker = FixedOpenHandleChecker(holders: [OpenHandleHolder(pid: 4711, processName: "less", path: rollout)])
        for cli in [CodexCLI.Choice.none, .executable(fixture.stub)] {
            let adapter = fixture.adapter(cli: cli, openHandles: checker)
            let sessions = try await adapter.sessions()
            #expect(sessions.count >= 5)
            await expectSameAsSingles(await adapter.deletePlans(for: sessions, destination: .quarantine), sessions) {
                try await adapter.deletePlan(for: $0, destination: .quarantine)
            }
            await expectSameAsSingles(await adapter.archivePlans(for: sessions), sessions) { try await adapter.archivePlan(for: $0) }
            await expectSameChecks(await adapter.liveChecks(for: sessions), sessions) { try await adapter.liveCheck($0) }
            let plans = await adapter.deletePlans(for: sessions, destination: .trash).compactMap(\.plan)
            #expect(plans.contains { $0.liveCheck.openHandles == .open })
        }
        // Codex running blocks every plan that touches its index, in a batch as alone.
        let running = fixture.adapter(cli: CodexCLI.Choice.none, running: [RunningProcess(pid: 77, name: "codex")],
                                      openFiles: [77: [fixture.openStateDatabase]])
        let sessions = try await running.sessions()
        await expectSameAsSingles(await running.deletePlans(for: sessions, destination: .trash), sessions) { try await running.deletePlan(for: $0) }
        #expect(await running.deletePlans(for: sessions, destination: .trash).allSatisfy { $0.plan?.liveCheck.isLive == true })
    }

    @Test("a Gemini archive batch and live checks match one session at a time")
    func geminiArchiveBatchMatchesSingles() async throws {
        let fixture = try GeminiFixtureHome()
        try fixture.addSyntheticChats(40)
        let adapter = fixture.adapter()
        let sessions = try await adapter.sessions()
        await expectSameAsSingles(await adapter.archivePlans(for: sessions), sessions) { try await adapter.archivePlan(for: $0) }
        await expectSameChecks(await adapter.liveChecks(for: sessions), sessions) { try await adapter.liveCheck($0) }
    }
}
