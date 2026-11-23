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
