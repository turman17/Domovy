@testable import DomovyCore
import Foundation
import os
import Testing

/// A throwaway folder for synthetic transcripts. Never the real home.
final class TempFolder: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("domovy-usage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func write(_ name: String, lines: [String]) throws -> URL {
        let file = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        return file
    }
}

/// A minimal adapter for tests: fixed sessions, counted reads. It never touches a file of its own.
final class StubAdapter: TokenUsageReporting, @unchecked Sendable {
    let kind: AgentKind
    let root: URL
    let listed: [Session]
    let usage: @Sendable (Session) -> TokenUsage?
    private let counter = OSAllocatedUnfairLock(initialState: (lists: 0, reads: 0))
    var listCount: Int { counter.withLock { $0.lists } }
    var readCount: Int { counter.withLock { $0.reads } }

    init(kind: AgentKind, root: URL, sessions: [Session], usage: @escaping @Sendable (Session) -> TokenUsage? = { _ in nil }) {
        self.kind = kind
        self.root = root
        self.listed = sessions
        self.usage = usage
    }

    func status() async -> AdapterStatus { .ready }
    func sessions() async throws -> [Session] {
        counter.withLock { $0.lists += 1 }
        return listed
    }
    func artifacts(of session: Session) async throws -> [Artifact] { [] }
    func liveCheck(_ session: Session) async throws -> LiveCheckResult {
        LiveCheckResult(isLive: false, reasons: [], checkedSignals: [], openHandles: .clear)
    }
    func deletePlan(for session: Session, destination: Destination) async throws -> Plan { throw AdapterError.notImplemented(kind, feature: "delete") }
    func archivePlan(for session: Session) async throws -> Plan { throw AdapterError.notImplemented(kind, feature: "archive") }
    func transcript(of session: Session, limit: Int, masking findings: [SecretFinding]) async throws -> Transcript { .empty }
    func footprint() async throws -> Footprint { throw AdapterError.notInstalled(kind) }
    func usageSources(of session: Session) -> [URL] { [session.transcriptURL] }
    func readTokenUsage(of session: Session) throws -> TokenUsage? {
        counter.withLock { $0.reads += 1 }
        return usage(session)
    }
}

func makeSession(_ id: String, agent: AgentKind = .claudeCode, project: String? = "/Users/dev/code/orbit-api",
                 lastActive: Date = Date(), size: Int64 = 1_000, transcript: URL = URL(fileURLWithPath: "/nonexistent"),
                 status: Session.Status = .idle) -> Session {
    Session(id: id, agent: agent, title: "Session \(id)", projectPath: project, lastActive: lastActive, sizeBytes: size,
            status: status, expiresAt: nil, transcriptURL: transcript)
}

@Suite("Token usage")
struct TokenUsageTests {
    @Test("Claude Code: one count per message id, cache fields, synthetic replies left out")
    func claudeCode() throws {
        let folder = try TempFolder()
        let file = try folder.write("t.jsonl", lines: [
            #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
            #"{"type":"assistant","message":{"id":"msg_1","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":100,"cache_read_input_tokens":0}}}"#,
            #"{"type":"assistant","message":{"id":"msg_1","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":10,"output_tokens":50,"cache_creation_input_tokens":100,"cache_read_input_tokens":0}}}"#,
            #"{"type":"assistant","message":{"id":"msg_2","model":"claude-opus-4-6","usage":{"input_tokens":3,"output_tokens":7,"cache_creation_input_tokens":0,"cache_read_input_tokens":900}}}"#,
            #"{"type":"assistant","message":{"id":"msg_3","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}"#,
        ])
        let usage = try #require(try UsageParsers.claudeCode([file]))
        #expect(usage.byModel["claude-sonnet-4-5-20250929"] == TokenCounts(input: 10, output: 50, cacheWrite: 100))
        #expect(usage.byModel["claude-opus-4-6"] == TokenCounts(input: 3, output: 7, cacheRead: 900))
        #expect(usage.totals.total == 10 + 50 + 100 + 3 + 7 + 900)
        #expect(usage.models == ["claude-opus-4-6", "claude-sonnet-4-5-20250929"])
        let none = try folder.write("none.jsonl", lines: [#"{"type":"user","message":{"content":"no usage"}}"#])
        #expect(try UsageParsers.claudeCode([none]) == nil)
    }

    @Test("Claude Code adapter counts subagent transcripts too")
    func claudeCodeSubagents() throws {
        let fixture = try FixtureHome()
        let adapter = ClaudeCodeAdapter(home: fixture.home)
        let folder = fixture.claudeDirectory.appendingPathComponent("projects/-Users-dev-code-orbit-api", isDirectory: true)
        let transcript = folder.appendingPathComponent("\(FixtureHome.ClaudeCode.idle).jsonl")
        let line = #"{"type":"assistant","message":{"id":"msg_main","model":"claude-haiku-4-5","usage":{"input_tokens":1,"output_tokens":2}}}"#
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()
        let sub = folder.appendingPathComponent("\(FixtureHome.ClaudeCode.idle)/subagents/agent-1.jsonl")
        try FileManager.default.createDirectory(at: sub.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((#"{"type":"assistant","message":{"id":"msg_sub","model":"claude-haiku-4-5","usage":{"input_tokens":4,"output_tokens":8}}}"# + "\n").utf8).write(to: sub)
        let session = makeSession(FixtureHome.ClaudeCode.idle, transcript: transcript)
        #expect(adapter.usageSources(of: session).contains(sub.standardizedFileURL))
        let usage = try #require(try adapter.readTokenUsage(of: session))
        #expect(usage.byModel["claude-haiku-4-5"] == TokenCounts(input: 5, output: 10))
    }

    @Test("Codex: running totals split by the model of each turn, cached input apart")
    func codex() throws {
        let folder = try TempFolder()
        let file = try folder.write("rollout.jsonl", lines: [
            #"{"type":"session_meta","payload":{"id":"x","cwd":"/tmp"}}"#,
            #"{"type":"turn_context","payload":{"model":"gpt-5-codex","cwd":"/tmp"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":100,"reasoning_output_tokens":40,"total_tokens":1100}}}}"#,
            #"{"type":"turn_context","payload":{"model":"gpt-5-mini"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1500,"cached_input_tokens":300,"output_tokens":180,"total_tokens":1680}}}}"#,
        ])
        let usage = try #require(try UsageParsers.codex(file))
        #expect(usage.byModel["gpt-5-codex"] == TokenCounts(input: 800, output: 100, cacheRead: 200))
        #expect(usage.byModel["gpt-5-mini"] == TokenCounts(input: 400, output: 80, cacheRead: 100))
        #expect(usage.totals.total == 1680)
    }

    @Test("Gemini CLI: a $set replaces the messages; cached input and thoughts are split out")
    func gemini() throws {
        let folder = try TempFolder()
        let file = try folder.write("session.jsonl", lines: [
            #"{"sessionId":"g1","projectHash":"h","startTime":"2026-11-01T10:00:00Z","kind":"main"}"#,
            #"{"id":"u1","type":"user","content":"hello"}"#,
            #"{"id":"a1","type":"gemini","content":"hi","model":"gemini-2.5-pro","tokens":{"input":999,"output":1,"cached":0,"thoughts":0,"total":1000}}"#,
            #"{"$set":{"messages":[{"id":"u1","type":"user","content":"hello"},{"id":"a1","type":"gemini","content":"hi","model":"gemini-2.5-pro","tokens":{"input":120,"output":30,"cached":20,"thoughts":10,"tool":0,"total":160}}]}}"#,
            #"{"id":"a2","type":"gemini","content":"more","model":"gemini-2.5-flash","tokens":{"input":50,"output":5,"cached":0,"thoughts":0,"total":55}}"#,
        ])
        let usage = try #require(try UsageParsers.gemini(file))
        #expect(usage.byModel["gemini-2.5-pro"] == TokenCounts(input: 100, output: 40, cacheRead: 20))
        #expect(usage.byModel["gemini-2.5-flash"] == TokenCounts(input: 50, output: 5))
    }

    @Test("Qwen Code: usageMetadata per assistant record")
    func qwen() throws {
        let folder = try TempFolder()
        let file = try folder.write("q.jsonl", lines: [
            #"{"uuid":"1","type":"user","message":{"role":"user","parts":[{"text":"hi"}]}}"#,
            #"{"uuid":"2","type":"assistant","model":"qwen3-coder-plus","usageMetadata":{"promptTokenCount":500,"candidatesTokenCount":40,"cachedContentTokenCount":100,"thoughtsTokenCount":10,"totalTokenCount":550}}"#,
            #"{"uuid":"3","type":"assistant","model":"qwen3-coder-plus","usageMetadata":{"promptTokenCount":600,"candidatesTokenCount":20,"totalTokenCount":620}}"#,
        ])
        let usage = try #require(try UsageParsers.qwen(file))
        #expect(usage.byModel["qwen3-coder-plus"] == TokenCounts(input: 1000, output: 70, cacheRead: 100))
        #expect(usage.cost == nil) // not in the price table
    }

    @Test("Copilot CLI: per-call usage events, else the shutdown summary")
    func copilot() throws {
        let folder = try TempFolder()
        let calls = try folder.write("events.jsonl", lines: [
            #"{"type":"session.start","data":{"cwd":"/tmp"}}"#,
            #"{"type":"assistant.usage","data":{"model":"claude-sonnet-4.5","inputTokens":1000,"outputTokens":100,"cacheReadTokens":600,"cacheWriteTokens":50}}"#,
            #"{"type":"session.shutdown","data":{"modelMetrics":{"claude-sonnet-4.5":{"usage":{"inputTokens":99999,"outputTokens":1}}}}}"#,
        ])
        let usage = try #require(try UsageParsers.copilot(calls))
        #expect(usage.byModel["claude-sonnet-4.5"] == TokenCounts(input: 400, output: 100, cacheRead: 600, cacheWrite: 50))
        #expect(PriceTable.standard.price(for: "claude-sonnet-4.5") != nil)
        let summary = try folder.write("summary.jsonl", lines: [
            #"{"type":"session.shutdown","data":{"modelMetrics":{"gpt-5":{"requests":{"count":2},"usage":{"inputTokens":300,"outputTokens":30,"cacheReadTokens":0}}}}}"#,
        ])
        #expect(try UsageParsers.copilot(summary)?.byModel["gpt-5"] == TokenCounts(input: 300, output: 30))
    }

    @Test("Zed: cumulative usage and model of the thread JSON")
    func zed() throws {
        let json = #"{"title":"t","messages":[],"cumulative_token_usage":{"input_tokens":12,"output_tokens":34,"cache_creation_input_tokens":5,"cache_read_input_tokens":6},"model":{"provider":"zed.dev","model":"claude-sonnet-4-5"}}"#
        let usage = try #require(UsageParsers.zed(Data(json.utf8)))
        #expect(usage.byModel["claude-sonnet-4-5"] == TokenCounts(input: 12, output: 34, cacheRead: 6, cacheWrite: 5))
        #expect(UsageParsers.zed(Data(#"{"title":"t"}"#.utf8)) == nil)
    }

    @Test("OpenCode: message tokens of the session and its subagents, with OpenCode's own cost")
    func openCode() throws {
        let folder = try TempFolder()
        let db = folder.url.appendingPathComponent("opencode.db")
        try CodexFixtureHome.buildDatabase("""
            CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT);
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, data TEXT);
            INSERT INTO session VALUES ('ses_a', NULL), ('ses_b', 'ses_a'), ('ses_c', NULL);
            INSERT INTO message VALUES ('m1', 'ses_a', '{"role":"user"}');
            INSERT INTO message VALUES ('m2', 'ses_a', '{"role":"assistant","modelID":"claude-sonnet-4-5","cost":0.25,"tokens":{"input":100,"output":20,"reasoning":5,"cache":{"read":300,"write":40}}}');
            INSERT INTO message VALUES ('m3', 'ses_b', '{"role":"assistant","modelID":"claude-sonnet-4-5","cost":0.05,"tokens":{"input":10,"output":2,"reasoning":0,"cache":{"read":0,"write":0}}}');
            INSERT INTO message VALUES ('m4', 'ses_c', '{"role":"assistant","modelID":"gpt-5","tokens":{"input":1,"output":1,"cache":{}}}');
            """, at: db)
        let usage = try #require(UsageParsers.openCode(database: db, sessionID: "ses_a"))
        #expect(usage.byModel["claude-sonnet-4-5"] == TokenCounts(input: 110, output: 27, cacheRead: 300, cacheWrite: 40))
        let cost = try #require(usage.cost)
        #expect(cost.source == .agent)
        #expect(abs(cost.usd - 0.30) < 0.0001)
        #expect(UsageParsers.openCode(database: db, sessionID: "ses_none") == nil)
    }

    @Test("Price table: provider prefixes, dotted versions, dates; unknown versions are not guessed")
    func prices() throws {
        let table = PriceTable.standard
        #expect(table.price(for: "claude-sonnet-4-5-20250929")?.input == 3)
        #expect(table.price(for: "anthropic/claude-opus-4.6")?.input == 5)
        #expect(table.price(for: "us.anthropic.claude-haiku-4-5-20251001-v1:0")?.input == 1)
        #expect(table.price(for: "claude-opus-4-20250514")?.input == 15)
        #expect(table.price(for: "gpt-5-codex")?.output == 10)
        #expect(table.price(for: "gpt-5-mini")?.input == 0.25)
        #expect(table.price(for: "gemini-2.5-flash-lite")?.input == 0.1)
        #expect(table.price(for: "gemini-3-pro-preview")?.input == 2)
        #expect(table.price(for: "gpt-5.7") == nil)
        #expect(table.price(for: "claude-opus-4-9") == nil)
        #expect(table.price(for: "") == nil)

        var usage = TokenUsage()
        usage.add(TokenCounts(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite: 1_000_000), model: "claude-sonnet-4-5")
        usage.add(TokenCounts(input: 500), model: "some-local-model")
        let cost = try #require(usage.cost)
        #expect(abs(cost.usd - (3 + 15 + 0.3 + 3.75)) < 0.0001)
        #expect(cost.source == .priceTable)
        #expect(cost.isPartial)
    }

    @Test("Cost in a table cell: whole dollars from $10, cents below, no approximation sign")
    func compactCost() {
        func text(_ usd: Double) -> String { CostEstimate(usd: usd, source: .priceTable, unpricedTokens: 0).compactText }
        let large = text(123.57)
        #expect(large.contains("124") && !large.contains("57") && !large.contains("\u{2248}"))
        #expect(text(2.9).contains("90"))
        #expect(text(0.004).hasPrefix("<") && text(0.004).contains("01"))
        #expect(!text(0).contains("00"))
    }

    @Test("Cache: kept by path, size and time; a changed transcript is read again; survives a new store")
    func cache() async throws {
        let folder = try TempFolder()
        let transcript = try folder.write("t.jsonl", lines: ["one"])
        let session = makeSession("s1", transcript: transcript)
        let unsupported = makeSession("s2", agent: .crush)
        let adapter = StubAdapter(kind: .claudeCode, root: folder.url, sessions: [session]) { session in
            var usage = TokenUsage()
            let size = (try? FileManager.default.attributesOfItem(atPath: session.transcriptURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            usage.add(TokenCounts(input: size), model: "claude-haiku-4-5")
            return usage
        }
        let storeRoot = folder.url.appendingPathComponent("store", isDirectory: true)
        let store = TokenUsageStore(storeRoot: storeRoot)
        #expect(await store.usage(for: [session], adapters: [adapter], cachedOnly: true).isEmpty)
        let first = await store.usage(for: [session, unsupported], adapters: [adapter])
        #expect(first[session.id]?.usage?.totals.input == 4)
        #expect(first[unsupported.id] == nil)
        #expect(adapter.readCount == 1)
        _ = await store.usage(for: [session], adapters: [adapter])
        #expect(adapter.readCount == 1)

        // A new store reads the cache file.
        let reloaded = TokenUsageStore(storeRoot: storeRoot)
        #expect(await reloaded.usage(for: [session], adapters: [adapter], cachedOnly: true)[session.id]?.usage?.totals.input == 4)

        try Data("one\ntwo\n".utf8).write(to: transcript)
        #expect(await reloaded.usage(for: [session], adapters: [adapter], cachedOnly: true).isEmpty)
        #expect(await reloaded.usage(for: [session], adapters: [adapter])[session.id]?.usage?.totals.input == 8)
        #expect(adapter.readCount == 2)

        // The cache holds counts and model ids, never transcript text.
        let cached = try String(contentsOf: reloaded.cacheFile, encoding: .utf8)
        #expect(!cached.contains("two"))
    }

    @Test("A session without usage is remembered as not recorded")
    func notRecorded() async throws {
        let folder = try TempFolder()
        let session = makeSession("s1", transcript: try folder.write("t.jsonl", lines: ["x"]))
        let adapter = StubAdapter(kind: .claudeCode, root: folder.url, sessions: [session])
        let store = TokenUsageStore(storeRoot: folder.url)
        #expect(await store.usage(for: [session], adapters: [adapter])[session.id] == .notRecorded)
        #expect(await store.usage(for: [session], adapters: [adapter], cachedOnly: true)[session.id] == .notRecorded)
        #expect(adapter.readCount == 1)
    }

    @Test("MCP list_sessions adds token fields only when asked")
    func mcpTokens() async throws {
        let fixture = try FixtureHome()
        let transcript = fixture.claudeDirectory.appendingPathComponent("projects/-Users-dev-code-orbit-api/\(FixtureHome.ClaudeCode.idle).jsonl")
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"type":"assistant","message":{"id":"m","model":"claude-sonnet-4-5","usage":{"input_tokens":1000,"output_tokens":100}}}"# + "\n").utf8))
        try handle.close()
        let context = DomovyContext(home: fixture.home, isCustomHome: true, adapters: [fixture.adapter()], executor: fixture.executor())
        let tools = DomovyTools(context: context)
        func row(_ arguments: [String: JSONValue]) async throws -> JSONValue {
            let outcome = await tools.call("list_sessions", arguments: arguments)
            let rows = try #require(outcome.structured["sessions"]?.arrayValue)
            return try #require(rows.first { $0["id"]?.stringValue == FixtureHome.ClaudeCode.idle })
        }
        #expect(try await row([:])["tokens"] == nil)
        let withTokens = try await row(["include_tokens": true])
        #expect(withTokens["tokens"]?["total"]?.intValue == 1100)
        #expect(withTokens["models"]?.arrayValue?.first?.stringValue == "claude-sonnet-4-5")
        #expect(withTokens["estimated_cost_usd"] != nil)
    }
}
