@testable import DomovyCore
import Foundation
import Testing

@Suite("Transcript search")
struct TranscriptSearchTests {
    /// A store folder of its own under the temp folder.
    final class Store: Sendable {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("domovy-search-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    /// Counts reads, so tests can tell which sessions were indexed again.
    final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func record(_ id: String) { lock.withLock { ids.append(id) } }
        var all: [String] { lock.withLock { ids } }
    }

    static func session(_ id: String, agent: AgentKind = .claudeCode, size: Int64 = 100, date: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> Session {
        Session(id: id, agent: agent, title: "Session \(id)", projectPath: "/Users/dev/code/orbit-api", lastActive: date,
                sizeBytes: size, status: .idle, expiresAt: nil, transcriptURL: URL(fileURLWithPath: "/tmp/fake/\(id).jsonl"))
    }

    static func transcript(_ texts: [String]) -> Transcript {
        Transcript(messages: texts.enumerated().map { index, text in
            TranscriptMessage(id: "\(index)", role: index.isMultiple(of: 2) ? .user : .assistant, timestamp: nil, blocks: [.text(text)])
        }, isTruncated: false)
    }

    static let texts: [String: [String]] = [
        "auth": ["The login keeps failing", "I fixed the auth bug in the session middleware", "Thanks, the authentication works now"],
        "cron": ["Migrate cron jobs to the queue", "Done: moved three jobs"],
        "docs": ["Write docs for the billing module", "Added a page about invoices and authors"],
    ]

    func update(_ index: TranscriptSearchIndex, _ sessions: [Session], reads: Reads = Reads()) async throws -> TranscriptSearchIndex.Summary {
        try await index.update(sessions: sessions) { session in
            reads.record(session.id)
            return Self.transcript(Self.texts[session.id] ?? [])
        }
    }

    @Test("indexes sessions, ranks by relevance and reports match counts and the first match")
    func indexAndSearch() async throws {
        let store = try Store()
        let index = try TranscriptSearchIndex(storeRoot: store.root)
        let summary = try await update(index, ["auth", "cron", "docs"].map { Self.session($0) })
        #expect(summary.indexed == 3)
        #expect(try await index.count() == 3)

        let hits = try await index.search(SearchQuery("auth"))
        // "auth" is a prefix of "auth", "authentication" and "authors".
        #expect(Set(hits.map(\.sessionID)) == ["auth", "docs"])
        #expect(hits.first?.sessionID == "auth")
        #expect(hits.first?.matchCount == 2)
        #expect(hits.first?.firstMessage == 1)
        // Stemming: "fixing" finds "fixed".
        #expect(try await index.search(SearchQuery("fixing")).map(\.sessionID) == ["auth"])
        #expect(try await index.search(SearchQuery("")).isEmpty)
        #expect(try await index.search(SearchQuery("auth"), agent: .codex).isEmpty)
    }

    @Test("phrase and prefix queries")
    func phraseAndPrefix() async throws {
        let store = try Store()
        let index = try TranscriptSearchIndex(storeRoot: store.root)
        _ = try await update(index, ["auth", "cron", "docs"].map { Self.session($0) })

        #expect(try await index.search(SearchQuery("\"auth bug\"")).map(\.sessionID) == ["auth"])
        #expect(try await index.search(SearchQuery("\"bug auth\"")).isEmpty)
        #expect(try await index.search(SearchQuery("\"cron jobs\" queue")).map(\.sessionID) == ["cron"])
        #expect(try await index.search(SearchQuery("migr")).map(\.sessionID) == ["cron"])
        #expect(try await index.search(SearchQuery("inv bill")).map(\.sessionID) == ["docs"])
        // Every word must match, in any message of the same session.
        #expect(try await index.search(SearchQuery("cron invoices")).isEmpty)
        let across = try await index.search(SearchQuery("login works"))
        #expect(across.map(\.sessionID) == ["auth"])
        #expect(across.first?.matchCount == 2)
        #expect(across.first?.firstMessage == 0)
        // The first match is the first message with every word.
        #expect(try await index.search(SearchQuery("middleware auth")).first?.firstMessage == 1)
        // FTS5 syntax typed by the user is only text.
        #expect(try await index.search(SearchQuery("auth OR NEAR( *")).count <= 2)
        #expect(SearchQuery("a \"b c\" NEAR(").ftsExpression == "\"a\"* AND \"b c\" AND \"near\"*")
    }

    @Test("only changed sessions are read again; removed sessions drop out")
    func incremental() async throws {
        let store = try Store()
        let index = try TranscriptSearchIndex(storeRoot: store.root)
        let sessions = ["auth", "cron", "docs"].map { Self.session($0) }
        _ = try await update(index, sessions)

        let reads = Reads()
        let again = try await update(index, sessions, reads: reads)
        #expect(reads.all.isEmpty)
        #expect(again.unchanged == 3)

        let changed = [Self.session("auth", size: 200), sessions[1]]
        let next = try await update(index, changed, reads: reads)
        #expect(reads.all == ["auth"])
        #expect(next.removed == 1)
        #expect(try await index.count() == 2)
        #expect(try await index.search(SearchQuery("invoices")).isEmpty)
        // Re-indexing replaced the old rows instead of adding to them.
        #expect(try await index.search(SearchQuery("auth")).first?.matchCount == 2)

        try await index.remove([(agent: .claudeCode, id: "cron")])
        #expect(try await index.search(SearchQuery("cron")).isEmpty)
        try await index.removeAll()
        #expect(try await index.count() == 0)
    }

    @Test("the index survives reopening and is owner-only and out of backups")
    func storage() async throws {
        let store = try Store()
        do {
            let index = try TranscriptSearchIndex(storeRoot: store.root)
            _ = try await update(index, [Self.session("auth")])
        }
        let file = TranscriptSearchIndex.file(storeRoot: store.root)
        #expect(FileSystem.posixPermissions(of: file) == 0o600)
        #expect(FileSystem.posixPermissions(of: file.deletingLastPathComponent()) == 0o700)
        let values = try file.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        let reopened = try TranscriptSearchIndex(storeRoot: store.root)
        #expect(try await reopened.search(SearchQuery("middleware")).map(\.sessionID) == ["auth"])
        // The FTS table is contentless: the words are not stored as text.
        let raw = try Data(contentsOf: file)
        #expect(raw.range(of: Data("session middleware".utf8)) == nil)
    }

    @Test("secrets are masked before indexing and in snippets")
    func secrets() async throws {
        let store = try Store()
        let index = try TranscriptSearchIndex(storeRoot: store.root)
        let secret = SecretSamples.github
        let text = "export GH_TOKEN=\(secret) and then deploy the orbit service"
        _ = try await index.update(sessions: [Self.session("s")]) { _ in Self.transcript([text]) }
        #expect(try await index.search(SearchQuery("deploy")).count == 1)
        #expect(try await index.search(SearchQuery(String(secret.suffix(12)))).isEmpty)
        #expect(try await index.search(SearchQuery(secret)).isEmpty)

        let snippet = try #require(SearchSnippet.make(from: Self.transcript([text]), query: SearchQuery("token deploy")))
        #expect(!snippet.text.contains(secret))
        #expect(snippet.text.contains("deploy"))
        #expect(snippet.highlights.map { String(snippet.text[$0]) }.contains("deploy"))
    }

    @Test("snippets cut around the first match and highlight every match")
    func snippets() throws {
        let long = String(repeating: "filler words here ", count: 20) + "we fixed the auth bug today " + String(repeating: "more text ", count: 30)
        let snippet = try #require(SearchSnippet.make(from: Self.transcript(["nothing", long]), query: SearchQuery("\"auth bug\" fixed"), preferring: 1))
        #expect(snippet.messageIndex == 1)
        #expect(snippet.text.hasPrefix("\u{2026}"))
        #expect(snippet.text.hasSuffix("\u{2026}"))
        #expect(snippet.text.count < 200)
        #expect(snippet.highlights.map { String(snippet.text[$0]) } == ["fixed", "auth bug"])
        #expect(SearchQuery("fixing").matches(in: "I fixed it").count == 1)
        #expect(SearchQuery("Пошук").matches(in: "новий пошук тут").count == 1)
    }

    @Test("indexes Claude Code and zstd Codex transcripts through their adapters")
    func adapters() async throws {
        let store = try Store()
        let index = try TranscriptSearchIndex(storeRoot: store.root)
        let claude = try FixtureHome()
        let codex = try CodexFixtureHome()
        let adapters: [any AgentAdapter] = [claude.adapter(), codex.adapter()]
        var sessions: [Session] = []
        for adapter in adapters { sessions += try await adapter.sessions() }
        let summary = try await index.update(sessions: sessions, adapters: adapters)
        #expect(summary.total == sessions.count)

        #expect(try await index.search(SearchQuery("\"token bucket\"")).map(\.sessionID) == [FixtureHome.ClaudeCode.idle])
        // The compressed rollout is `.jsonl.zst`.
        let compressed = try #require(sessions.first { $0.id == CodexFixtureHome.IDs.compressed })
        #expect(compressed.transcriptURL.pathExtension == "zst")
        #expect(try await index.search(SearchQuery("cron queue")).map(\.sessionID).contains(CodexFixtureHome.IDs.compressed))
        #expect(try await index.search(SearchQuery("exponential backoff"), agent: .codex).map(\.sessionID) == [CodexFixtureHome.IDs.idle])
    }

    @Test("search_sessions returns ids, titles and match counts, never transcript text")
    func mcp() async throws {
        let fixture = try FixtureHome()
        let context = DomovyContext(home: fixture.home, isCustomHome: true, adapters: [fixture.adapter()], executor: fixture.executor())
        let tools = DomovyTools(context: context)
        #expect(DomovyTools.definitions.contains { $0.name == "search_sessions" && $0.annotations.readOnly })

        let outcome = await tools.call("search_sessions", arguments: ["query": "token bucket"])
        #expect(!outcome.isError)
        let rows = try #require(outcome.structured["sessions"]?.arrayValue)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row["id"]?.stringValue == FixtureHome.ClaudeCode.idle)
        #expect(row["match_count"]?.intValue == 1)
        #expect(Set(row.objectValue?.keys.map { $0 } ?? []) == ["id", "agent", "agent_name", "title", "last_active", "match_count"])
        // The reply holds the title (the first prompt) but no message text.
        let encoded = String(decoding: outcome.structured.encoded(), as: UTF8.self) + outcome.text
        #expect(!encoded.contains("middleware"))
        #expect(!encoded.lowercased().contains("token bucket"))

        let none = await tools.call("search_sessions", arguments: ["query": "zebra"])
        #expect(none.structured["sessions"]?.arrayValue?.isEmpty == true)
        #expect(await tools.call("search_sessions", arguments: [:]).isError)
    }
}
