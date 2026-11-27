@testable import DomovyCore
import Foundation
import Testing

/// Antigravity CLI conversations are deleted and archived by Domovy itself, with Antigravity
/// quit; the app's own (unverified) store is read-only.
@Suite("Antigravity adapter")
struct AntigravityAdapterTests {
    typealias IDs = AntigravityFixtureHome.IDs

    @Test("lists conversations of both stores with titles and workspaces")
    func listsSessions() async throws {
        let fixture = try AntigravityFixtureHome()
        let adapter = fixture.adapter()
        #expect(await adapter.status() == .ready)
        let sessions = try await adapter.sessions()
        #expect(Set(sessions.map(\.id)) == [IDs.uploader, IDs.landing, IDs.open, IDs.history, IDs.preview])

        let uploader = try #require(sessions.first { $0.id == IDs.uploader })
        #expect(uploader.title == "Add retries to the uploader") // from the metadata cache
        #expect(uploader.projectPath == "/Users/dev/code/orbit-api")
        #expect(uploader.status == .idle)
        let landing = try #require(sessions.first { $0.id == IDs.landing })
        #expect(landing.title == "Sketch the landing page") // from conversation_summaries.db
        #expect(landing.projectPath == "/Users/dev/code/landing-site")
        // No summary: the first prompt of history.jsonl, cleaned of context tags.
        let history = try #require(sessions.first { $0.id == IDs.history })
        #expect(history.title == "fix the flaky login test")
        #expect(history.projectPath == "/Users/dev/code/auth-service")
        // An empty title: the first line of the summary's preview.
        let preview = try #require(sessions.first { $0.id == IDs.preview })
        #expect(preview.title == "Draft the release notes")
    }

    @Test("titles: the first line, wrappers cleaned whole")
    func titleCleanup() {
        #expect(AntigravityIndex.clean("first line\nsecond") == "first line")
        #expect(AntigravityIndex.clean("<session_context>\nbranch: main\n</session_context>\nship it") == "ship it")
        #expect(AntigravityIndex.clean("<session_context>only context</session_context>") == nil)
        #expect(AntigravityIndex.clean("  ") == nil)
    }

    @Test("a presence lock makes a conversation live unless nobody holds it")
    func presenceLock() async throws {
        let fixture = try AntigravityFixtureHome()
        // Handles cannot be checked: the lock alone counts.
        let unsure = try await fixture.adapter().session(matching: IDs.open)
        #expect(unsure.status == .live)
        // Handles checked and the lock is not held: a stale lock from a crash.
        let stale = try await fixture.adapter(openHandles: FixedOpenHandleChecker(holders: [])).session(matching: IDs.open)
        #expect(stale.status == .idle)
    }

    @Test("artifacts: database files, brain folder, annotations and history lines")
    func artifacts() async throws {
        let fixture = try AntigravityFixtureHome()
        let adapter = fixture.adapter()
        let uploader = try await adapter.artifacts(of: try await adapter.session(matching: IDs.uploader))
        #expect(uploader.contains { $0.url.lastPathComponent == "\(IDs.uploader).db" })
        #expect(uploader.contains { $0.kind == .folder && $0.url.lastPathComponent == IDs.uploader })
        let history = try #require(uploader.first { $0.kind == .indexEntry })
        #expect(history.match == IndexMatch(key: "conversationId", value: IDs.uploader))
        let open = try await adapter.artifacts(of: try await adapter.session(matching: IDs.open))
        #expect(open.contains { $0.note == "Annotations" })
    }

    @Test("delete plan: files, summaries row, metadata entry and history lines")
    func deletePlan() async throws {
        let fixture = try AntigravityFixtureHome()
        let adapter = fixture.adapter(openHandles: FixedOpenHandleChecker(holders: []))
        let landing = try await adapter.session(matching: IDs.landing)
        let plan = try await adapter.deletePlan(for: landing, destination: .quarantine)
        #expect(!plan.liveCheck.isLive)
        let moved = Set(plan.moves.map(\.source.lastPathComponent))
        #expect(moved == ["\(IDs.landing).db", IDs.landing, "\(IDs.landing).pb"])
        #expect(plan.indexEdits.map(\.file.lastPathComponent) == ["history.jsonl"])
        #expect(plan.indexEdits.first?.lineNumbers.count == 2)
        let rows = try #require(plan.databaseEdits.first?.rows.first)
        #expect(rows.table == "conversation_summaries" && rows.column == "conversation_id" && rows.key == IDs.landing)
        #expect(plan.jsonRemovals.map(\.key) == [IDs.landing])
        #expect(plan.mustNotBeRunning == [AntigravityAdapter.processMatcher])
        #expect(plan.moves.allSatisfy { !$0.source.path.contains("conversation_summaries") && !$0.source.path.contains("/cache/") })

        // A conversation with no summary row and no metadata entry: files and history only.
        let history = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.history))
        #expect(history.databaseEdits.isEmpty && history.jsonRemovals.isEmpty)
        #expect(history.indexEdits.first?.lineNumbers.count == 3)
    }

    @Test("an index of an unknown shape is left alone with a remark")
    func unknownIndexShape() async throws {
        let fixture = try AntigravityFixtureHome()
        try Data(#"["not","the","verified","shape"]"#.utf8).write(to: fixture.cliStore.appendingPathComponent("cache/conversation_metadata.json"))
        let adapter = fixture.adapter(openHandles: FixedOpenHandleChecker(holders: []))
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.uploader))
        #expect(plan.jsonRemovals.isEmpty)
        #expect(plan.remarks.contains { $0.contains("conversation_metadata.json") })
        #expect(!plan.moves.isEmpty)
    }

    @Test("delete runs and undo puts every file and index entry back byte for byte")
    func executeAndUndo() async throws {
        let fixture = try AntigravityFixtureHome()
        let adapter = fixture.adapter(openHandles: FixedOpenHandleChecker(holders: []))
        let cli = fixture.cliStore
        let metadata = cli.appendingPathComponent("cache/conversation_metadata.json")
        let history = cli.appendingPathComponent("history.jsonl")
        let summaries = cli.appendingPathComponent("conversation_summaries.db")
        let before = (metadata: try Data(contentsOf: metadata), history: try Data(contentsOf: history), summaries: try Data(contentsOf: summaries))
        let metadataDate = try #require(FileSystem.modificationDate(of: metadata))

        // Two conversations in one batch: both edit the same summaries database and metadata file.
        let sessions = [try await adapter.session(matching: IDs.uploader), try await adapter.session(matching: IDs.landing)]
        let plans = await adapter.deletePlans(for: sessions, destination: .quarantine).compactMap(\.plan)
        #expect(plans.count == 2)
        let executor = fixture.executor()
        let entries = try executor.execute(plans)

        for id in [IDs.uploader, IDs.landing] {
            #expect(!FileManager.default.fileExists(atPath: cli.appendingPathComponent("conversations/\(id).db").path))
            #expect(!FileManager.default.fileExists(atPath: cli.appendingPathComponent("brain/\(id)").path))
        }
        let cut = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any]
        #expect((cut?["conversations"] as? [String: Any])?.isEmpty == true)
        #expect(FileSystem.modificationDate(of: metadata) == metadataDate)
        let lines = String(decoding: try Data(contentsOf: history), as: UTF8.self)
        #expect(!lines.contains(IDs.uploader) && !lines.contains(IDs.landing) && lines.contains(IDs.history) && lines.contains("/help"))
        let reader = try #require(SQLiteReader(url: summaries))
        #expect(reader.count(table: "conversation_summaries", column: "conversation_id", equals: IDs.landing) == 0)
        #expect(reader.count(table: "conversation_summaries", column: "conversation_id", equals: IDs.preview) == 1)

        // The app undoes a batch entry by entry, newest first.
        for entry in entries.reversed() { _ = try executor.undo(entry) }
        #expect(try Data(contentsOf: metadata) == before.metadata)
        #expect(try Data(contentsOf: history) == before.history)
        #expect(try Data(contentsOf: summaries) == before.summaries)
        for id in [IDs.uploader, IDs.landing] {
            #expect(FileManager.default.fileExists(atPath: cli.appendingPathComponent("conversations/\(id).db").path))
        }
        #expect(FileManager.default.fileExists(atPath: cli.appendingPathComponent("brain/\(IDs.landing)/implementation_plan.md").path))
    }

    @Test("nothing changes while Antigravity runs")
    func refusesWhileRunning() async throws {
        let fixture = try AntigravityFixtureHome()
        let running = [RunningProcess(pid: 700, name: "agy")]
        let adapter = fixture.adapter(openHandles: FixedOpenHandleChecker(holders: []), running: running)
        let session = try await adapter.session(matching: IDs.landing)
        let plan = try await adapter.deletePlan(for: session)
        #expect(plan.liveCheck.isLive)
        #expect(plan.liveCheck.reasons.contains { $0.contains("Antigravity is running") && $0.contains("Quit it to delete") })
        #expect(throws: ExecutorError.self) { try fixture.executor(running: running).execute(plan) }

        // Started after the plan was made: the executor checks again.
        let quiet = try await fixture.adapter(openHandles: FixedOpenHandleChecker(holders: [])).deletePlan(for: session)
        #expect(!quiet.liveCheck.isLive)
        #expect(throws: ExecutorError.self) { try fixture.executor(running: running).execute(quiet) }
        #expect(FileManager.default.fileExists(atPath: fixture.cliStore.appendingPathComponent("conversations/\(IDs.landing).db").path))
    }

    @Test("the app's unverified store stays read-only")
    func appStoreReadOnly() async throws {
        let fixture = try AntigravityFixtureHome()
        let adapter = fixture.adapter(openHandles: FixedOpenHandleChecker(holders: []))
        let open = try await adapter.session(matching: IDs.open)
        await #expect(throws: AdapterError.readOnly(.antigravity, reason: AntigravityAdapter.readOnlyReason)) {
            _ = try await adapter.deletePlan(for: open)
        }
        await #expect(throws: AdapterError.self) { _ = try await adapter.archivePlan(for: open) }
        // Only the app's store: the whole adapter is read-only.
        try FileManager.default.removeItem(at: fixture.cliStore)
        #expect(await adapter.status() == .readOnly(reason: AntigravityAdapter.readOnlyReason))
    }

    @Test("archive compresses the database and brain files in place, and undo restores them")
    func archive() async throws {
        let fixture = try AntigravityFixtureHome()
        let brainFile = fixture.cliStore.appendingPathComponent("brain/\(IDs.uploader)/notes.md")
        try Data(String(repeating: "a plan line that compresses well\n", count: 4_000).utf8).write(to: brainFile)
        let adapter = fixture.adapter(openHandles: FixedOpenHandleChecker(holders: []))
        let session = try await adapter.session(matching: IDs.uploader)
        let plan = try await adapter.archivePlan(for: session)
        #expect(plan.compressions.map(\.file.lastPathComponent).contains("notes.md"))
        #expect(plan.mustNotBeRunning == [AntigravityAdapter.processMatcher])
        let date = FileSystem.modificationDate(of: brainFile)
        let executor = fixture.executor()
        let entry = try executor.execute(plan)
        #expect(APFSCompression.isCompressed(brainFile))
        #expect(FileSystem.modificationDate(of: brainFile) == date)
        let archived = try await adapter.session(matching: IDs.uploader)
        #expect(archived.isArchived)
        // Already compressed: nothing to do, and it says so.
        let again = try await adapter.archivePlan(for: archived)
        #expect(again.isEmpty)
        #expect(again.summary.contains("Nothing to compress"))
        _ = try executor.undo(entry)
        #expect(!APFSCompression.isCompressed(brainFile))
    }

    @Test("conversations past the newest 480 are expiring, past 500 they go at the next start")
    func conversationCap() async throws {
        let fixture = try AntigravityFixtureHome()
        let folder = fixture.cliStore.appendingPathComponent("conversations", isDirectory: true)
        let start = Date().addingTimeInterval(-10 * 86_400)
        for n in 0..<503 {
            let id = String(format: "dddddddd-0000-4000-8000-%012d", n)
            let file = folder.appendingPathComponent("\(id).db")
            FileManager.default.createFile(atPath: file.path, contents: Data())
            try fixture.setDate(file, start.addingTimeInterval(-Double(n) * 60))
        }
        let sessions = try await fixture.adapter().sessions().filter { $0.transcriptURL.path.hasPrefix(folder.path) }
        #expect(sessions.count == 507)
        let ranked = sessions.sorted { $0.lastActive > $1.lastActive }
        #expect(ranked.prefix(480).allSatisfy { $0.status == .idle })
        #expect(ranked[480].status == .expiring)
        #expect(ranked[480].retentionNote?.contains("number 481") == true)
        #expect(ranked[504].retentionNote?.contains("next time Antigravity starts") == true)
        #expect(ranked.allSatisfy { $0.expiresAt == nil })
    }

    @Test("footprint marks conversations, logs and what Antigravity needs")
    func footprint() async throws {
        let fixture = try AntigravityFixtureHome()
        let footprint = try await fixture.adapter().footprint()
        let byName = Dictionary(uniqueKeysWithValues: footprint.categories.map { ($0.name, $0) })
        #expect(byName["Antigravity CLI: Conversations"]?.disposition == .consequences)
        #expect(byName["Antigravity CLI: Logs and crash reports"]?.disposition == .safe)
        #expect(byName["Antigravity CLI: Settings, sign-in, tools"]?.disposition == .keep)
        #expect(byName["Antigravity: Conversations"] != nil)
        #expect(footprint.categories.allSatisfy { $0.cleanupID == nil })
    }

    @Test("not installed without a store")
    func notInstalled() async throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("domovy-ag-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let adapter = AntigravityAdapter(geminiHome: empty, openHandles: UnavailableOpenHandleChecker(), processes: FixedProcessLister([]))
        #expect(await adapter.status() == .notInstalled)
        await #expect(throws: AdapterError.self) { _ = try await adapter.footprint() }
    }

    @Test("Gemini CLI and Antigravity processes are told apart from Google's Gemini app")
    func classification() {
        func agent(_ name: String, _ arguments: [String]? = nil) -> AgentKind? {
            ProcessClassifier.agent(of: RawProcess(pid: 500, ppid: 1, uid: 501, name: name, startMicros: 1), arguments: { arguments })
        }
        #expect(agent("node", ["node", "/opt/homebrew/lib/node_modules/@google/gemini-cli/bundle/gemini.js"]) == .gemini)
        #expect(agent("gemini") == .gemini)
        #expect(agent("Gemini") == nil)
        #expect(agent("agy") == .antigravity)
        #expect(agent("Antigravity") == .antigravity)
        #expect(ProcessClassifier.agentHint(path: "/Users/dev/.gemini/antigravity-cli/bin/agentapi") == .antigravity)
        #expect(AntigravityAdapter.processMatcher.matches("agy"))
        #expect(!GeminiAdapter.processMatcher.matches("Gemini"))
    }
}
