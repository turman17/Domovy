@testable import DomovyCore
import Foundation
import Testing

/// Antigravity is read-only: it lists, measures and explains, and never plans a change.
@Suite("Antigravity adapter")
struct AntigravityAdapterTests {
    typealias IDs = AntigravityFixtureHome.IDs

    @Test("lists conversations of both stores with titles and workspaces")
    func listsSessions() async throws {
        let fixture = try AntigravityFixtureHome()
        let adapter = fixture.adapter()
        #expect(await adapter.status() == .readOnly(reason: AntigravityAdapter.readOnlyReason))
        let sessions = try await adapter.sessions()
        #expect(Set(sessions.map(\.id)) == [IDs.uploader, IDs.landing, IDs.open])

        let uploader = try #require(sessions.first { $0.id == IDs.uploader })
        #expect(uploader.title == "Add retries to the uploader") // from the metadata cache
        #expect(uploader.projectPath == "/Users/dev/code/orbit-api")
        #expect(uploader.status == .idle)
        let landing = try #require(sessions.first { $0.id == IDs.landing })
        #expect(landing.title == "Sketch the landing page") // from conversation_summaries.db
        #expect(landing.projectPath == "/Users/dev/code/landing-site")
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

    @Test("delete and archive plans change nothing and say why")
    func readOnlyPlans() async throws {
        let fixture = try AntigravityFixtureHome()
        let adapter = fixture.adapter()
        let session = try await adapter.session(matching: IDs.uploader)
        let delete = try await adapter.deletePlan(for: session, destination: .quarantine)
        #expect(delete.isEmpty)
        #expect(delete.summary.contains("read-only"))
        #expect(delete.remarks.contains { $0.contains("conversations/\(IDs.uploader).db") && $0.contains("brain/\(IDs.uploader)") })
        let archive = try await adapter.archivePlan(for: session)
        #expect(archive.isEmpty)
        let executor = Executor(storeRoot: fixture.storeRoot, processes: FixedProcessLister([]))
        #expect(throws: ExecutorError.self) { try executor.execute(delete) }
        #expect(FileManager.default.fileExists(atPath: fixture.cliStore.appendingPathComponent("conversations/\(IDs.uploader).db").path))
        await #expect(throws: AdapterError.self) {
            _ = try await RedactionPlanner.plan(for: session, findings: [], adapter: adapter)
        }
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
        #expect(sessions.count == 505)
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
