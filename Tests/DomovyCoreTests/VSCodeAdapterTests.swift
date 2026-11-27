@testable import DomovyCore
import Foundation
import Testing

/// A throwaway home with VS Code's `User` folder copied from `Tests/Fixtures/vscode/1.138/`, its
/// two `state.vscdb` built from `Tests/Fixtures/vscode/sql/` (the global one also holds Gemini
/// Code Assist's chats) and Gemini Code Assist's checkpoints from
/// `Tests/Fixtures/gemini-code-assist/2.104/`. Never the real VS Code folder. The chat files are
/// written from VS Code's source (see `VSCodeChatIndex`), not copied from a real install.
final class VSCodeFixtureHome: Sendable {
    enum IDs {
        static let json = "5e550001-1111-4111-8111-111111111111"
        static let log = "5e550002-2222-4222-8222-222222222222"
        static let fileOnly = "5e550003-3333-4333-8333-333333333333"
        static let entryOnly = "5e550004-4444-4444-8444-444444444444"
        static let emptyEntry = "5e550005-5555-4555-8555-555555555555"
        static let emptyWindow = "5e550006-6666-4666-8666-666666666666"
        static let gemini = "9c0de001-1111-4111-8111-111111111111"
        static let geminiAgent = "9c0de002-2222-4222-8222-222222222222"
        static let trace = "1a2b3c4d5e6f7a8b"
    }

    let home: URL
    let storeRoot: URL
    var support: URL { home.appendingPathComponent("Library/Application Support/Code", isDirectory: true) }
    var workspace: URL { support.appendingPathComponent("User/workspaceStorage/7a1b2c3d4e5f6", isDirectory: true) }
    var workspaceDatabase: URL { workspace.appendingPathComponent("state.vscdb") }
    var globalStorage: URL { support.appendingPathComponent("User/globalStorage", isDirectory: true) }
    var globalDatabase: URL { globalStorage.appendingPathComponent("state.vscdb") }
    var checkpoint: URL { globalStorage.appendingPathComponent("google.geminicodeassist/chat_checkpoint_files/\(IDs.trace)", isDirectory: true) }
    func chatFile(_ id: String, _ suffix: String = "json") -> URL { workspace.appendingPathComponent("chatSessions/\(id).\(suffix)") }
    var editing: URL { workspace.appendingPathComponent("chatEditingSessions/\(IDs.json)", isDirectory: true) }

    init() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("domovy-vscode-tests-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        storeRoot = base.appendingPathComponent("store", isDirectory: true)
        let fixtures = FixtureHome.fixturesRoot
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        try fm.copyItem(at: fixtures.appendingPathComponent("vscode/1.138/User", isDirectory: true), to: support.appendingPathComponent("User", isDirectory: true))
        try fm.copyItem(at: fixtures.appendingPathComponent("gemini-code-assist/2.104/globalStorage/google.geminicodeassist", isDirectory: true),
                        to: globalStorage.appendingPathComponent("google.geminicodeassist", isDirectory: true))
        try CodexFixtureHome.buildDatabase(String(contentsOf: fixtures.appendingPathComponent("vscode/sql/workspace.sql"), encoding: .utf8), at: workspaceDatabase)
        try CodexFixtureHome.buildDatabase(String(contentsOf: fixtures.appendingPathComponent("vscode/sql/global.sql"), encoding: .utf8), at: globalDatabase)
    }

    deinit {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    func chat(running: [RunningProcess]? = [], holders: [OpenHandleHolder] = []) -> VSCodeChatAdapter {
        VSCodeChatAdapter(home: home, openHandles: FixedOpenHandleChecker(holders: holders), processes: FixedProcessLister(running))
    }

    func gemini(running: [RunningProcess]? = [], holders: [OpenHandleHolder] = []) -> GeminiCodeAssistAdapter {
        GeminiCodeAssistAdapter(home: home, openHandles: FixedOpenHandleChecker(holders: holders), processes: FixedProcessLister(running))
    }

    func executor(running: [RunningProcess]? = []) -> Executor {
        Executor(storeRoot: storeRoot, processes: FixedProcessLister(running))
    }

    func value(_ key: String, in database: URL) -> String? {
        SQLiteReader(url: database)?.rows("SELECT CAST(value AS TEXT) FROM ItemTable WHERE key = ?1", [key]).first?.first ?? nil
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}

@Suite("VS Code chat adapter")
struct VSCodeChatAdapterTests {
    typealias IDs = VSCodeFixtureHome.IDs

    @Test("lists chats with and without files and entries; empty entries stay out")
    func lists() async throws {
        let fixture = try VSCodeFixtureHome()
        let adapter = fixture.chat()
        #expect(await adapter.status() == .ready)
        let sessions = try await adapter.sessions()
        #expect(Set(sessions.map(\.id)) == [IDs.json, IDs.log, IDs.fileOnly, IDs.entryOnly, IDs.emptyWindow])
        let json = try #require(sessions.first { $0.id == IDs.json })
        #expect(json.title == "Fix the flaky upload test")
        #expect(json.projectPath == "/Users/dev/code/orbit-api")
        #expect(json.lastActive == Date(timeIntervalSince1970: 1_795_166_100))
        #expect(json.transcriptURL == fixture.chatFile(IDs.json))
        #expect(json.agentLabel == "VS Code Chat")
        #expect(sessions.first { $0.id == IDs.fileOnly }?.title == "Rename the CLI flags") // from the file
        #expect(sessions.first { $0.id == IDs.entryOnly }?.transcriptURL == fixture.workspaceDatabase)
        #expect(sessions.first { $0.id == IDs.emptyWindow }?.projectPath == nil)
    }

    @Test("artifacts: files, edit state and the list entry")
    func artifacts() async throws {
        let fixture = try VSCodeFixtureHome()
        let adapter = fixture.chat()
        let artifacts = try await adapter.artifacts(of: try await adapter.session(matching: IDs.json))
        #expect(artifacts.map(\.url) == [fixture.chatFile(IDs.json), fixture.editing, fixture.workspaceDatabase])
        #expect(artifacts.map(\.kind) == [.file, .folder, .indexEntry])
    }

    @Test("transcript reads the .json file and replays the .jsonl log")
    func transcript() async throws {
        let fixture = try VSCodeFixtureHome()
        let adapter = fixture.chat()
        let json = try await adapter.transcript(of: try await adapter.session(matching: IDs.json), limit: 10)
        #expect(json.messages.map(\.role) == [.user, .assistant])
        #expect(json.messages[1].blocks.count == 3)
        #expect(json.messages[1].blocks[1] == .toolCall("Read upload.ts"))
        let log = try await adapter.transcript(of: try await adapter.session(matching: IDs.log), limit: 10)
        #expect(log.messages.map(\.role) == [.user, .assistant, .user])
        #expect(log.messages[1].blocks == [.text("Added loading=lazy to the hero image.")])
        #expect(VSCodeChatIndex.chat(at: fixture.chatFile(IDs.log, "jsonl"))?["customTitle"] as? String == "Lazy load the hero image")
    }

    @Test("delete plan moves the files and edit state and cuts the list entry")
    func deletePlan() async throws {
        let fixture = try VSCodeFixtureHome()
        let adapter = fixture.chat()
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.json), destination: .quarantine)
        #expect(plan.moves.map(\.source) == [fixture.chatFile(IDs.json), fixture.editing])
        let edit = try #require(plan.databaseEdits.first)
        #expect(edit.database == fixture.workspaceDatabase)
        #expect(edit.rows.isEmpty)
        #expect(edit.listRemovals.first?.memberPath == ["entries"])
        #expect(edit.listRemovals.first?.id == IDs.json)
        #expect(plan.mustNotBeRunning.map(\.appName) == ["VS Code"])
        #expect(plan.acknowledgement == VSCodeChatAdapter.acknowledgement)
        #expect(!plan.liveCheck.isLive)

        let fileOnly = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.fileOnly))
        #expect(fileOnly.databaseEdits.isEmpty && fileOnly.acknowledgement == nil)
        #expect(fileOnly.moves.map(\.source) == [fixture.chatFile(IDs.fileOnly)])
        let entryOnly = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.entryOnly))
        #expect(entryOnly.moves.isEmpty && entryOnly.databaseEdits.count == 1)
    }

    @Test("delete removes the files and exactly one entry; undo puts both back")
    func deleteRoundTrip() async throws {
        let fixture = try VSCodeFixtureHome()
        let adapter = fixture.chat()
        let index = try #require(fixture.value(VSCodeLayout.indexKey, in: fixture.workspaceDatabase))
        let other = try #require(fixture.value("workbench.panel.chat", in: fixture.workspaceDatabase))
        var plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.json), destination: .quarantine)
        plan.isAcknowledged = true
        let executor = fixture.executor()
        let entry = try executor.execute(plan)
        #expect(!fixture.exists(fixture.chatFile(IDs.json)))
        #expect(!fixture.exists(fixture.editing))
        let after = try #require(fixture.value(VSCodeLayout.indexKey, in: fixture.workspaceDatabase))
        #expect(!after.contains(IDs.json))
        #expect(after.contains(IDs.log) && after.contains(IDs.entryOnly))
        #expect((try? JSONSerialization.jsonObject(with: Data(after.utf8))) != nil)
        #expect(fixture.value("workbench.panel.chat", in: fixture.workspaceDatabase) == other)
        #expect(try await adapter.sessions().contains { $0.id == IDs.json } == false)

        _ = try executor.undo(entry)
        #expect(fixture.exists(fixture.chatFile(IDs.json)))
        #expect(fixture.exists(fixture.editing))
        #expect(fixture.value(VSCodeLayout.indexKey, in: fixture.workspaceDatabase) == index)
    }

    @Test("archive compresses the chat file in place; undo decompresses")
    func archive() async throws {
        let fixture = try VSCodeFixtureHome()
        let adapter = fixture.chat()
        let plan = try await adapter.archivePlan(for: try await adapter.session(matching: IDs.json))
        #expect(plan.compressions.map(\.file) == [fixture.chatFile(IDs.json)])
        let before = try Data(contentsOf: fixture.chatFile(IDs.json))
        let entry = try fixture.executor().execute(plan)
        #expect(APFSCompression.isCompressed(fixture.chatFile(IDs.json)))
        #expect(try Data(contentsOf: fixture.chatFile(IDs.json)) == before)
        #expect(try await adapter.session(matching: IDs.json).status == .archived)
        _ = try fixture.executor().undo(entry)
        #expect(!APFSCompression.isCompressed(fixture.chatFile(IDs.json)))
    }

    @Test("VS Code running makes its chats live and the executor refuses")
    func vsCodeRunning() async throws {
        let fixture = try VSCodeFixtureHome()
        let running = [RunningProcess(pid: 500, name: "Code"), RunningProcess(pid: 501, name: "Code Helper (Renderer)")]
        let adapter = fixture.chat(running: running)
        #expect(try await adapter.sessions().allSatisfy { $0.status == .live })
        #expect(try await adapter.deletePlan(for: try await adapter.session(matching: IDs.json)).liveCheck.isLive)
        var quiet = try await fixture.chat().deletePlan(for: try await fixture.chat().session(matching: IDs.json))
        quiet.isAcknowledged = true
        #expect(throws: ExecutorError.self) { try fixture.executor(running: running).execute(quiet) }
        #expect(fixture.exists(fixture.chatFile(IDs.json)))
        // Codex and Cursor are not VS Code.
        let others = fixture.chat(running: [RunningProcess(pid: 1, name: "codex"), RunningProcess(pid: 2, name: "Cursor")])
        #expect(try await others.sessions().allSatisfy { $0.status != .live })
    }

    @Test("an unknown index shape makes the adapter read-only")
    func unknownIndex() async throws {
        let fixture = try VSCodeFixtureHome()
        try CodexFixtureHome.buildDatabase("UPDATE ItemTable SET value = '[1,2]' WHERE key = 'chat.ChatSessionStore.index';", at: fixture.workspaceDatabase)
        let adapter = fixture.chat()
        guard case .readOnly = await adapter.status() else { Issue.record("not read-only"); return }
        await #expect(throws: AdapterError.self) { try await adapter.deletePlan(for: try await adapter.session(matching: IDs.fileOnly)) }
    }

    @Test("footprint links chat folders to Sessions and marks the embeddings cache safe")
    func footprint() async throws {
        let fixture = try VSCodeFixtureHome()
        let footprint = try await fixture.chat().footprint()
        #expect(footprint.categories.first { $0.name == "Chat sessions" }?.guidance == .manageInSessions)
        #expect(footprint.categories.first { $0.name == "Copilot Chat caches" }?.disposition == .safe)
    }
}

@Suite("Gemini Code Assist adapter")
struct GeminiCodeAssistAdapterTests {
    typealias IDs = VSCodeFixtureHome.IDs

    @Test("lists the chats inside VS Code's state with titles, dates and projects")
    func lists() async throws {
        let fixture = try VSCodeFixtureHome()
        let adapter = fixture.gemini()
        #expect(await adapter.status() == .ready)
        let sessions = try await adapter.sessions()
        #expect(sessions.map(\.id) == [IDs.geminiAgent, IDs.gemini])
        let chat = try #require(sessions.first { $0.id == IDs.gemini })
        #expect(chat.title == "Explain the queue worker")
        #expect(chat.projectPath == "/Users/dev/code/ledger")
        #expect(chat.lastActive == Date(timeIntervalSince1970: 1_783_592_400))
        #expect(chat.transcriptURL == fixture.globalDatabase)
        let artifacts = try await adapter.artifacts(of: chat)
        #expect(artifacts.map(\.url) == [fixture.globalDatabase, fixture.checkpoint])
        let transcript = try await adapter.transcript(of: chat, limit: 10)
        #expect(transcript.messages.map(\.role) == [.user, .assistant])
    }

    @Test("delete cuts one chat out of the value, moves its checkpoints, and undo restores")
    func deleteRoundTrip() async throws {
        let fixture = try VSCodeFixtureHome()
        let adapter = fixture.gemini()
        let original = try #require(fixture.value("google.geminicodeassist", in: fixture.globalDatabase))
        var plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.gemini), destination: .quarantine)
        #expect(plan.moves.map(\.source) == [fixture.checkpoint])
        #expect(plan.databaseEdits.first?.listRemovals.first?.memberPath == ["geminiCodeAssist.chatThreads", "k7Qz2LmN4pR8sT1vW3xY"])
        #expect(plan.acknowledgement == GeminiCodeAssistAdapter.acknowledgement)
        #expect(plan.summary.contains("takes it out of state.vscdb"))
        plan.isAcknowledged = true
        let executor = fixture.executor()
        let entry = try executor.execute(plan)
        let after = try #require(fixture.value("google.geminicodeassist", in: fixture.globalDatabase))
        #expect(!after.contains(IDs.gemini) && after.contains(IDs.geminiAgent))
        #expect(after.contains("geminicodeassist.lastOpenedVersion"))
        #expect(!fixture.exists(fixture.checkpoint))
        #expect(fixture.exists(fixture.globalStorage.appendingPathComponent("google.geminicodeassist/chat_checkpoint_files/ffff000011112222")))
        #expect(fixture.value(VSCodeLayout.indexKey, in: fixture.globalDatabase)?.contains(IDs.emptyWindow) == true)
        #expect(try await adapter.sessions().map(\.id) == [IDs.geminiAgent])

        _ = try executor.undo(entry)
        #expect(fixture.value("google.geminicodeassist", in: fixture.globalDatabase) == original)
        #expect(fixture.exists(fixture.checkpoint))
    }

    @Test("agent-mode chats say their Gemini CLI chat stays; archive has nothing to do")
    func agentModeAndArchive() async throws {
        let fixture = try VSCodeFixtureHome()
        let adapter = fixture.gemini()
        let session = try await adapter.session(matching: IDs.geminiAgent)
        #expect(try await adapter.deletePlan(for: session).remarks.contains { $0.contains("agent mode") })
        let archive = try await adapter.archivePlan(for: session)
        #expect(archive.isEmpty && archive.remarks == [GeminiCodeAssistAdapter.archiveRemark])
    }

    @Test("VS Code running blocks the delete; an unknown shape is read-only")
    func refusals() async throws {
        let fixture = try VSCodeFixtureHome()
        let running = [RunningProcess(pid: 500, name: "Code")]
        let adapter = fixture.gemini(running: running)
        #expect(try await adapter.deletePlan(for: try await adapter.session(matching: IDs.gemini)).liveCheck.isLive)
        var quiet = try await fixture.gemini().deletePlan(for: try await fixture.gemini().session(matching: IDs.gemini))
        quiet.isAcknowledged = true
        #expect(throws: ExecutorError.self) { try fixture.executor(running: running).execute(quiet) }
        #expect(fixture.value("google.geminicodeassist", in: fixture.globalDatabase)?.contains(IDs.gemini) == true)

        try CodexFixtureHome.buildDatabase(
            "UPDATE ItemTable SET value = json_set(value, '$.\"geminiCodeAssist.chatThreads\"', json('[]')) WHERE key = 'google.geminicodeassist';",
            at: fixture.globalDatabase)
        guard case .readOnly = await fixture.gemini().status() else { Issue.record("not read-only"); return }
    }

    @Test("footprint measures the chats inside state.vscdb and keeps sign-in")
    func footprint() async throws {
        let fixture = try VSCodeFixtureHome()
        let footprint = try await fixture.gemini().footprint()
        let chats = try #require(footprint.categories.first { $0.name == "Chats" })
        #expect(chats.guidance == .manageInSessions && chats.sizeBytes > 0)
        #expect(footprint.categories.first { $0.name == "Chat checkpoints" }?.disposition == .consequences)
    }
}

@Suite("Codex app liveness")
struct CodexAppLivenessTests {
    @Test("the Codex app's embedded app-server and the ChatGPT app block when they use CODEX_HOME; the classic ChatGPT app does not")
    func appServer() throws {
        let home = URL(fileURLWithPath: "/tmp/fixture-home/.codex", isDirectory: true)
        let matcher = CodexAdapter.processMatcher(codexHome: home)
        let appServer = FixedProcessLister([RunningProcess(pid: 10, name: "codex")], openFiles: [10: ["/tmp/fixture-home/.codex/logs_2.sqlite"]])
        #expect(!appServer.blockingReasons([matcher]).isEmpty)
        let app = FixedProcessLister([RunningProcess(pid: 11, name: "ChatGPT")], openFiles: [11: ["/tmp/fixture-home/.codex/state_5.sqlite"]])
        #expect(!app.blockingReasons([matcher]).isEmpty)
        let classic = FixedProcessLister([RunningProcess(pid: 12, name: "ChatGPT")], openFiles: [12: ["/tmp/other/chat.db"]])
        #expect(classic.blockingReasons([matcher]).isEmpty)
    }

    @Test("originator values read as the app that started the thread")
    func origins() {
        #expect(CodexIndex.origin("codex_work_desktop") == "Codex app")
        #expect(CodexIndex.origin("codex_vscode") == "VS Code")
        #expect(CodexIndex.origin("codex-tui") == "CLI")
        #expect(CodexIndex.origin("codex_cli_rs") == "CLI")
        #expect(CodexIndex.origin("zed") == "Zed")
        #expect(CodexIndex.origin(nil) == nil)
    }
}
