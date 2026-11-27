@testable import DomovyCore
import Foundation
import Testing

/// End to end over stdio, the way an agent talks to Domovy: the built `domo mcp --root <fixture>`
/// when the test can find it next to the test bundle, else the same server in-process over pipes.
@Suite("MCP over stdio, end to end")
struct MCPStdioTests {
    typealias IDs = FixtureHome.ClaudeCode

    /// A JSON-RPC client over a pair of file handles, one message per line.
    final class Client: @unchecked Sendable {
        private let input: FileHandle
        private let output: FileHandle
        private var buffer = Data()
        private var nextID = 0
        private let stop: () -> Void
        let usesBinary: Bool

        init(home: URL) throws {
            let toServer = Pipe(), fromServer = Pipe()
            input = toServer.fileHandleForWriting
            output = fromServer.fileHandleForReading
            if let domo = Self.builtDomo() {
                let process = Process()
                process.executableURL = domo
                process.arguments = ["mcp", "--root", home.path]
                process.standardInput = toServer
                process.standardOutput = fromServer
                process.standardError = FileHandle.nullDevice
                try process.run()
                usesBinary = true
                stop = { if process.isRunning { process.terminate() }; process.waitUntilExit() }
            } else {
                let server = MCPServer(tools: DomovyTools(context: DomovyContext(home: home, isCustomHome: true)))
                let reading = toServer.fileHandleForReading, writing = fromServer.fileHandleForWriting
                let task = Task { await server.run(input: reading, output: writing) }
                usesBinary = false
                stop = { task.cancel() }
            }
        }

        deinit { try? input.close(); stop() }

        /// `domo` beside the test bundle (`swift test` builds every product into the same folder).
        static func builtDomo() -> URL? {
            let bundle = Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") } ?? Bundle.main
            let candidate = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("domo")
            return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
        }

        func send(_ message: JSONValue) {
            input.write(message.encoded() + Data("\n".utf8))
        }

        func readMessage() throws -> JSONValue {
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer = Data(buffer[buffer.index(after: newline)...])
                    return try JSONDecoder().decode(JSONValue.self, from: Data(line))
                }
                let chunk = output.availableData
                guard !chunk.isEmpty else { throw CancellationError() }
                buffer.append(chunk)
            }
        }

        func request(_ method: String, _ params: JSONValue = [:]) throws -> JSONValue {
            nextID += 1
            send(["jsonrpc": "2.0", "id": .int(nextID), "method": .string(method), "params": params])
            let reply = try readMessage()
            #expect(reply["id"] == .int(nextID))
            return reply
        }

        /// A tool call's `result`, failing the test on a protocol error.
        func call(_ name: String, _ arguments: JSONValue = [:]) throws -> JSONValue {
            let reply = try request("tools/call", ["name": .string(name), "arguments": arguments])
            return try #require(reply["result"], "\(name): \(reply)")
        }
    }

    /// The fixture with its interactive session marker pointing at launchd (pid 1, always
    /// running), so the real liveness check sees it live, as in `.devhome`.
    private func fixture() throws -> FixtureHome {
        let fixture = try FixtureHome()
        let sessions = fixture.claudeDirectory.appendingPathComponent("sessions")
        let marker = try String(contentsOf: sessions.appendingPathComponent("4242.json"), encoding: .utf8)
        try marker.replacingOccurrences(of: "\"pid\":4242", with: "\"pid\":1").write(to: sessions.appendingPathComponent("1.json"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: sessions.appendingPathComponent("4242.json"))
        // APFS compression skips files of 16 KiB or less; give archive something to compress, keeping the date.
        let expiring = fixture.transcript(IDs.expiring, project: "-Users-dev-code-landing-site")
        let date = try FileManager.default.attributesOfItem(atPath: expiring.path)[.modificationDate]
        let bulk = (1...2_000).map { "{\"type\":\"tool_result\",\"n\":\($0),\"content\":\"synthetic build output\"}\n" }.joined()
        let handle = try FileHandle(forWritingTo: expiring)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(bulk.utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: date as Any], ofItemAtPath: expiring.path)
        return fixture
    }

    @Test("initialize, all eleven tools, the token flow with undo, and every error case")
    func everyTool() throws {
        let fixture = try fixture()
        let client = try Client(home: fixture.home)
        let idle = fixture.transcript(IDs.idle, project: "-Users-dev-code-orbit-api")
        let expiring = fixture.transcript(IDs.expiring, project: "-Users-dev-code-landing-site")

        let initialize = try client.request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "e2e", "version": "1"]])
        #expect(initialize["result"]?["serverInfo"]?["name"]?.stringValue == "domovy")
        client.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        #expect(try client.request("ping")["result"] == .object([:]))

        let names = try #require(try client.request("tools/list")["result"]?["tools"]?.arrayValue).compactMap { $0["name"]?.stringValue }
        #expect(Set(names) == ["list_sessions", "search_sessions", "disk_usage", "list_processes", "plan_delete", "plan_archive",
                               "delete_sessions", "archive_sessions", "undo", "list_rules", "plan_rules"])

        // Reads.
        let listed = try client.call("list_sessions")
        #expect(listed["isError"] == false)
        let sessions = try #require(listed["structuredContent"]?["sessions"]?.arrayValue)
        #expect(sessions.first { $0["id"]?.stringValue == IDs.live }?["status"]?.stringValue == "live")
        #expect(try client.call("list_sessions", ["include_tokens": true, "limit": 2])["structuredContent"]?["sessions"]?.arrayValue?.count == 2)
        let filtered = try #require(try client.call("list_sessions", ["agent": "claude-code", "status": "idle", "project": "orbit", "older_than_days": 1, "min_size": "1 byte"])["structuredContent"]?["sessions"]?.arrayValue)
        let filteredIDs: [String] = filtered.compactMap { $0["id"]?.stringValue }
        #expect(filteredIDs.contains(IDs.idle))
        #expect(!filteredIDs.contains(IDs.live))
        #expect(try client.call("disk_usage")["structuredContent"]?["agents"]?.arrayValue?.isEmpty == false)
        #expect(try client.call("list_processes", ["orphans_only": true])["isError"] == false)
        let found = try client.call("search_sessions", ["query": "rate limiting"])
        #expect(found["structuredContent"]?["sessions"]?.arrayValue?.contains { $0["id"]?.stringValue == IDs.idle } == true)
        let rules = try #require(try client.call("list_rules")["structuredContent"]?["rules"]?.arrayValue)
        #expect(!rules.isEmpty)
        #expect(try client.call("plan_rules", ["include_disabled": true])["isError"] == false)

        // Delete with a token, once; undo puts it back.
        let plan = try client.call("plan_delete", ["session_ids": [.string(IDs.idle)], "destination": "quarantine"])
        let token = try #require(plan["structuredContent"]?["plan_token"]?.stringValue)
        #expect(FileManager.default.fileExists(atPath: idle.path), "planning changes nothing")
        let deleted = try client.call("delete_sessions", ["plan_token": .string(token)])
        #expect(deleted["isError"] == false, "\(deleted)")
        #expect(!FileManager.default.fileExists(atPath: idle.path))
        #expect(try client.call("delete_sessions", ["plan_token": .string(token)])["isError"] == true, "a token works once")
        let undoID = try #require(deleted["structuredContent"]?["undo_id"]?.stringValue)
        #expect(try client.call("undo", ["undo_id": .string(undoID)])["isError"] == false)
        #expect(FileManager.default.fileExists(atPath: idle.path))

        // Archive with a token; undo by "last".
        let modified = try FileManager.default.attributesOfItem(atPath: expiring.path)[.modificationDate] as? Date
        let archivePlan = try client.call("plan_archive", ["session_ids": [.string(IDs.expiring)]])
        let archiveToken = try #require(archivePlan["structuredContent"]?["plan_token"]?.stringValue)
        let wrong = try client.call("delete_sessions", ["plan_token": .string(archiveToken)])
        #expect(wrong["isError"] == true, "an archive token does not delete")
        #expect(FileManager.default.fileExists(atPath: expiring.path))
        let secondToken = try #require(try client.call("plan_archive", ["session_ids": [.string(IDs.expiring)]])["structuredContent"]?["plan_token"]?.stringValue)
        let archived = try client.call("archive_sessions", ["plan_token": .string(secondToken)])
        #expect(archived["isError"] == false, "\(archived)")
        #expect(try client.call("undo", ["undo_id": "last"])["isError"] == false)
        #expect(try FileManager.default.attributesOfItem(atPath: expiring.path)[.modificationDate] as? Date == modified, "dates are kept")

        // The live session gets no token.
        let live = try client.call("plan_delete", ["session_ids": [.string(IDs.live)]])
        #expect(live["structuredContent"]?["plan_token"] == nil)
        #expect(live["structuredContent"]?["blocked"]?.arrayValue?.isEmpty == false || live["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("live") == true)

        // Tool errors the model can read.
        for (name, arguments) in [
            ("delete_sessions", ["plan_token": "not-a-token"]),
            ("archive_sessions", [:]),
            ("plan_delete", [:]),
            ("list_sessions", ["agent": "nobody"]),
            ("list_sessions", ["bogus": 1]),
            ("search_sessions", [:]),
            ("disk_usage", ["extra": true]),
        ] as [(String, JSONValue)] {
            let result = try client.call(name, arguments)
            #expect(result["isError"] == true, "\(name) \(arguments)")
        }
        // Protocol errors.
        #expect(try client.request("tools/call", ["name": "no_such_tool", "arguments": [:]])["error"]?["code"] == -32602)
        #expect(try client.request("resources/list")["error"]?["code"] == -32601)
        client.send(.string("not an object"))
        #expect(try client.readMessage()["error"]?["code"] == -32600)
    }
}
