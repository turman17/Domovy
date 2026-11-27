@testable import DomovyCore
import Foundation
import Testing

@Suite("MCP server")
struct MCPServerTests {
    typealias IDs = FixtureHome.ClaudeCode

    /// A clock tests can move forward.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date()
        var now: Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
    }

    private func tools(_ fixture: FixtureHome, clock: Clock = Clock()) -> DomovyTools {
        let context = DomovyContext(home: fixture.home, isCustomHome: true, adapters: [fixture.adapter()], executor: fixture.executor())
        return DomovyTools(context: context, now: { clock.now })
    }

    private func send(_ server: MCPServer, _ message: JSONValue) async throws -> JSONValue {
        let reply = try #require(await server.handle(message.encoded()))
        return try JSONDecoder().decode(JSONValue.self, from: reply)
    }

    private func call(_ server: MCPServer, id: Int, _ name: String, _ arguments: JSONValue = [:]) async throws -> JSONValue {
        let reply = try await send(server, ["jsonrpc": "2.0", "id": .int(id), "method": "tools/call", "params": ["name": .string(name), "arguments": arguments]])
        return try #require(reply["result"])
    }

    @Test("initialize, tools/list and list_sessions round trip on a fixture home")
    func roundTrip() async throws {
        let fixture = try FixtureHome()
        let server = MCPServer(tools: tools(fixture))

        let initialized = try await send(server, [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]],
        ])
        #expect(initialized["id"] == 1)
        #expect(initialized["result"]?["protocolVersion"]?.stringValue == "2025-06-18")
        #expect(initialized["result"]?["capabilities"]?["tools"] != nil)
        #expect(initialized["result"]?["serverInfo"]?["name"]?.stringValue == "domovy")
        #expect(initialized["result"]?["serverInfo"]?["version"]?.stringValue == DomovyVersion.current)

        // Notifications get no reply.
        #expect(await server.handle(JSONValue.object(["jsonrpc": "2.0", "method": "notifications/initialized"]).encoded()) == nil)
        #expect(try await send(server, ["jsonrpc": "2.0", "id": "p", "method": "ping"])["result"] == .object([:]))

        let listed = try await send(server, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let tools = try #require(listed["result"]?["tools"]?.arrayValue)
        let names = Set(tools.compactMap { $0["name"]?.stringValue })
        #expect(names.isSuperset(of: ["list_sessions", "disk_usage", "plan_delete", "plan_archive", "delete_sessions", "archive_sessions", "undo"]))
        for tool in tools {
            #expect(tool["inputSchema"]?["type"]?.stringValue == "object")
            let annotations = try #require(tool["annotations"])
            let name = tool["name"]?.stringValue ?? ""
            if name == "delete_sessions" || name == "undo" {
                #expect(annotations["destructiveHint"] == true)
                #expect(annotations["readOnlyHint"] == false)
            }
            if name.hasPrefix("list") || name.hasPrefix("plan") || name == "disk_usage" {
                #expect(annotations["readOnlyHint"] == true)
            }
        }

        let result = try await call(server, id: 3, "list_sessions")
        #expect(result["isError"] == false)
        let sessions = try #require(result["structuredContent"]?["sessions"]?.arrayValue)
        let ids = sessions.compactMap { $0["id"]?.stringValue }
        #expect(ids.contains(IDs.idle))
        #expect(ids.contains(IDs.live))
        #expect(sessions.first { $0["id"]?.stringValue == IDs.live }?["status"]?.stringValue == "live")
        #expect(sessions.first { $0["id"]?.stringValue == IDs.idle }?["title"]?.stringValue == "Add rate limiting to the orbit API")
        // Titles only: the assistant's reply in the transcript never appears.
        let text = String(decoding: result.encoded(), as: UTF8.self)
        #expect(!text.contains("token bucket middleware"))

        let filtered = try await call(server, id: 4, "list_sessions", ["status": "live"])
        let live = try #require(filtered["structuredContent"]?["sessions"]?.arrayValue)
        #expect(live.allSatisfy { $0["status"]?.stringValue == "live" })
        #expect(live.contains { $0["id"]?.stringValue == IDs.live })
        #expect(!live.contains { $0["id"]?.stringValue == IDs.idle })

        // Protocol errors.
        let unknown = try await send(server, ["jsonrpc": "2.0", "id": 5, "method": "resources/list"])
        #expect(unknown["error"]?["code"] == -32601)
        let badTool = try await send(server, ["jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": ["name": "rm_rf"]])
        #expect(badTool["error"]?["code"] == -32602)
        let parse = try JSONDecoder().decode(JSONValue.self, from: try #require(await server.handle(Data("{not json".utf8))))
        #expect(parse["error"]?["code"] == -32700)
    }

    @Test("plan then delete with the token moves files; undo puts them back")
    func planDeleteUndo() async throws {
        let fixture = try FixtureHome()
        let tools = tools(fixture)
        let transcript = fixture.transcript(IDs.idle, project: "-Users-dev-code-orbit-api")

        let plan = await tools.call("plan_delete", arguments: ["session_ids": [.string(String(IDs.idle.prefix(8)))], "destination": "quarantine"])
        #expect(!plan.isError)
        let token = try #require(plan.structured["plan_token"]?.stringValue)
        #expect(plan.structured["plans"]?.arrayValue?.first?["live_check"]?["is_live"] == false)
        #expect(FileManager.default.fileExists(atPath: transcript.path), "planning changes nothing")

        let done = await tools.call("delete_sessions", arguments: ["plan_token": .string(token)])
        #expect(!done.isError, "\(done.text)")
        #expect(!FileManager.default.fileExists(atPath: transcript.path))
        let undoID = try #require(done.structured["undo_id"]?.stringValue)

        // A token works once.
        let again = await tools.call("delete_sessions", arguments: ["plan_token": .string(token)])
        #expect(again.isError)

        let undone = await tools.call("undo", arguments: ["undo_id": .string(undoID)])
        #expect(!undone.isError, "\(undone.text)")
        #expect(FileManager.default.fileExists(atPath: transcript.path))
    }

    @Test("unknown, expired and wrong-action tokens are refused and change nothing")
    func tokenEnforcement() async throws {
        let fixture = try FixtureHome()
        let clock = Clock()
        let tools = tools(fixture, clock: clock)
        let transcript = fixture.transcript(IDs.idle, project: "-Users-dev-code-orbit-api")

        let unknown = await tools.call("delete_sessions", arguments: ["plan_token": .string(UUID().uuidString)])
        #expect(unknown.isError)
        #expect(unknown.text.contains("Unknown plan_token"))
        let missing = await tools.call("delete_sessions", arguments: [:])
        #expect(missing.isError)

        let plan = await tools.call("plan_delete", arguments: ["session_ids": [.string(IDs.idle)], "destination": "quarantine"])
        let token = try #require(plan.structured["plan_token"]?.stringValue)
        clock.advance(11 * 60)
        let expired = await tools.call("delete_sessions", arguments: ["plan_token": .string(token)])
        #expect(expired.isError)
        #expect(expired.text.contains("minutes old"))

        let archive = await tools.call("plan_delete", arguments: ["session_ids": [.string(IDs.idle)], "destination": "quarantine"])
        let deleteToken = try #require(archive.structured["plan_token"]?.stringValue)
        let wrong = await tools.call("archive_sessions", arguments: ["plan_token": .string(deleteToken)])
        #expect(wrong.isError)
        #expect(FileManager.default.fileExists(atPath: transcript.path))
    }

    @Test("live and just-written sessions get no token and cannot be deleted")
    func liveRefused() async throws {
        let fixture = try FixtureHome()
        let clock = Clock()
        let tools = tools(fixture, clock: clock)

        let live = await tools.call("plan_delete", arguments: ["session_ids": [.string(IDs.live)]])
        #expect(live.structured["plan_token"] == nil)
        #expect(live.structured["blocked"]?.arrayValue?.first?["reason"]?.stringValue?.contains("live") == true)

        // A session written to a minute ago may be the caller's own: refused too.
        try fixture.setTranscriptDate(IDs.idle, project: "-Users-dev-code-orbit-api", clock.now.addingTimeInterval(-60))
        let recent = await tools.call("plan_archive", arguments: ["session_ids": [.string(IDs.idle)]])
        #expect(recent.structured["plan_token"] == nil)

        // Planned while idle, live by the time it runs: refused at execution.
        try fixture.setTranscriptDate(IDs.idle, project: "-Users-dev-code-orbit-api", clock.now.addingTimeInterval(-2 * 86_400))
        let plan = await tools.call("plan_delete", arguments: ["session_ids": [.string(IDs.idle)], "destination": "quarantine"])
        let token = try #require(plan.structured["plan_token"]?.stringValue)
        try fixture.setTranscriptDate(IDs.idle, project: "-Users-dev-code-orbit-api", clock.now)
        let refused = await tools.call("delete_sessions", arguments: ["plan_token": .string(token)])
        #expect(refused.isError)
        #expect(refused.text.contains("Nothing was changed"))
        #expect(FileManager.default.fileExists(atPath: fixture.transcript(IDs.idle, project: "-Users-dev-code-orbit-api").path))
    }

    @Test("a plan that changed since the user saw it is refused")
    func changedPlanRefused() async throws {
        let fixture = try FixtureHome()
        let tools = tools(fixture)
        let plan = await tools.call("plan_delete", arguments: ["session_ids": [.string(IDs.idle)], "destination": "quarantine"])
        let token = try #require(plan.structured["plan_token"]?.stringValue)
        // Another copy of the transcript appears after planning; the plan would now move it too.
        let copy = fixture.claudeDirectory.appendingPathComponent("projects/-Users-dev-code-orbit-api/\(IDs.idle).orphaned-20261102-zz9.jsonl")
        try Data("{}\n".utf8).write(to: copy)
        let result = await tools.call("delete_sessions", arguments: ["plan_token": .string(token)])
        #expect(result.isError)
        #expect(result.text.contains("changed since the user saw it"))
        #expect(FileManager.default.fileExists(atPath: fixture.transcript(IDs.idle, project: "-Users-dev-code-orbit-api").path))
    }

    @Test("titles that look like secrets are masked")
    func titleMasking() {
        let session = Session(id: "x", agent: .claudeCode, title: "use key sk-ant-api03-AbCdEf0123456789AbCdEf0123456789AbCdEf0123456789AbCdEf0123456789AbCdEf0123456789-AbCdEfAA please",
                              projectPath: nil, lastActive: Date(), sizeBytes: 0, status: .idle, expiresAt: nil, transcriptURL: URL(fileURLWithPath: "/tmp/x"))
        let title = DomovyTools.safeTitle(session)
        #expect(!title.contains("AbCdEf0123456789AbCdEf0123456789AbCdEf0123456789"))
    }

    @Test("sizes parse from bytes and text")
    func sizes() {
        #expect(DomovyTools.parseSize(1_000) == 1_000)
        #expect(DomovyTools.parseSize("50 MB") == 50_000_000)
        #expect(DomovyTools.parseSize("1.5gb") == 1_500_000_000)
        #expect(DomovyTools.parseSize("526 bytes") == 526)
        #expect(DomovyTools.parseSize("1,2 MB") == 1_200_000)
        #expect(DomovyTools.parseSize("lots") == nil)
    }
}

@Suite("MCP agent ids")
struct MCPAgentIDTests {
    @Test("every session agent has a unique id the tools accept; published ids stay")
    func everyAgent() {
        let kinds = AgentKind.allCases.filter(\.hasSessions)
        #expect(SessionAgent.allCases == kinds)
        #expect(Set(DomovyTools.agentIDs).count == kinds.count)
        for kind in kinds { #expect(SessionAgent.parse(SessionAgent.id(of: kind)) == kind) }
        #expect(DomovyTools.agentIDs.prefix(8) == ["claude-code", "codex", "cursor", "gemini", "antigravity", "opencode", "copilot", "zed"])
        #expect(SessionAgent.id(of: .vsCodeChat) == "vscode-chat")
        #expect(SessionAgent.id(of: .geminiCodeAssist) == "gemini-code-assist")
        #expect(SessionAgent.id(of: .continueDev) == "continue")
        #expect(SessionAgent.parse("Kilo Code") == .kilo)
        #expect(SessionAgent.parse("ollama") == nil)
    }
}
