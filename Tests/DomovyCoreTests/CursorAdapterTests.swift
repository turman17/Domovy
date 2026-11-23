@testable import DomovyCore
import Foundation
import Testing

/// Cursor against a fixture home with a synthetic `state.vscdb`. Never the real database, never `~`.
@Suite("Cursor adapter")
struct CursorAdapterTests {
    typealias IDs = CursorFixtureHome.IDs

    /// The first entry of the fixture's chat list, exactly as stored.
    static let namedHeader = #"{"composerId":"ca11ab1e-1111-4111-8111-111111111111","name":"Fix the flaky upload test","createdAt":1795100000000,"lastUpdatedAt":1795166100000,"unifiedMode":"agent","workspaceIdentifier":{"id":"9a8b7c6d","uri":{"fsPath":"/Users/dev/code/orbit-api","scheme":"file"}}},  "#

    private func session(_ adapter: CursorAdapter, _ id: String) async throws -> Session {
        try await adapter.session(matching: id)
    }

    @Test("lists editor chats with titles, workspaces and row sizes, and CLI chats; empty drafts stay out")
    func listsChats() async throws {
        let fixture = try CursorFixtureHome()
        let adapter = fixture.adapter()
        #expect(await adapter.status() == .ready)
        let sessions = try await adapter.sessions()
        #expect(Set(sessions.map(\.id)) == [IDs.named, IDs.untitled, IDs.small, IDs.cli])

        let named = try #require(sessions.first { $0.id == IDs.named })
        #expect(named.title == "Fix the flaky upload test")
        #expect(named.projectPath == "/Users/dev/code/orbit-api")
        #expect(named.lastActive == Date(timeIntervalSince1970: 1_795_166_100))
        #expect(named.status == .idle)
        #expect(named.transcriptURL == fixture.database)
        #expect(CursorAdapter.isEditorChat(named))
        let untitled = try #require(sessions.first { $0.id == IDs.untitled })
        #expect(untitled.title == "Make the hero image lazy load")
        #expect(untitled.projectPath == "/Users/dev/code/landing-site")
        #expect(named.sizeBytes > 18_000) // three padded messages and a checkpoint
        #expect(untitled.sizeBytes < named.sizeBytes)

        let cli = try #require(sessions.first { $0.id == IDs.cli })
        #expect(cli.title == "Rename the CLI flags")
        #expect(!CursorAdapter.isEditorChat(cli))
    }

    @Test("transcript follows the conversation order, user and assistant, with secrets masked")
    func transcript() async throws {
        let fixture = try CursorFixtureHome()
        try fixture.write("""
            UPDATE cursorDiskKV SET value = json_set(value, '$.text', 'Deploy with \(SecretSamples.github) please')
            WHERE key = 'bubbleId:\(IDs.named):a0000003-0000-4000-8000-000000000003';
            """)
        let adapter = fixture.adapter()
        let transcript = try await adapter.transcript(of: try await session(adapter, IDs.named), limit: 2)
        #expect(transcript.messages.map(\.role) == [.user, .assistant])
        #expect(transcript.messages.first?.blocks == [.text("The upload test fails one run in ten. Find out why.")])
        #expect(transcript.isTruncated)

        let all = try await adapter.transcript(of: try await session(adapter, IDs.named), limit: 50)
        guard case .text(let last) = all.messages.last?.blocks.first else { Issue.record("no text"); return }
        #expect(!last.contains(SecretSamples.github))
        #expect(last.hasPrefix("Deploy with "))
    }

    @Test("delete plan lists the exact rows of the chat, its list entry and its plain-text copy")
    func deletePlan() async throws {
        let fixture = try CursorFixtureHome()
        let adapter = fixture.adapter()
        let plan = try await adapter.deletePlan(for: try await session(adapter, IDs.named), destination: .quarantine)
        let edit = try #require(plan.databaseEdits.first)
        #expect(edit.database == fixture.database)
        #expect(edit.files.map(\.lastPathComponent) == ["state.vscdb", "state.vscdb-wal", "state.vscdb-shm", "state.vscdb-journal"])
        #expect(edit.rows.map(\.key) == [
            "composerData:\(IDs.named)", "bubbleId:\(IDs.named):", "checkpointId:\(IDs.named):",
            "messageRequestContext:\(IDs.named):", "codeBlockDiff:\(IDs.named):", "agentKv:\(IDs.named):",
        ])
        #expect(edit.rows.map(\.count) == [1, 3, 1, 1, 1, 1])
        #expect(edit.rows.dropFirst().allSatisfy { $0.isPrefix })
        #expect(edit.rowCount == 8)
        #expect(edit.listRemovals.map(\.key) == ["composer.composerHeaders"])
        #expect(edit.listRemovals.first?.listField == "allComposers")
        #expect(plan.moves.map(\.source) == [fixture.agentTranscript])
        #expect(plan.mustNotBeRunning == [CursorLayout.appMatcher])
        #expect(plan.acknowledgement == CursorAdapter.acknowledgement)
        #expect(plan.remarks.contains(CursorAdapter.spaceRemark))
        #expect(plan.remarks.contains { $0.hasPrefix("1 agentKv row belongs to no one chat") })
        #expect(plan.remarks.contains { $0.contains("state.vscdb.backup") })
        #expect(!plan.liveCheck.isLive)
        #expect(plan.summary.contains("deletes 8 rows"))
    }

    @Test("delete removes exactly those rows, cuts the list entry byte for byte, never vacuums, and undo restores")
    func deleteRoundTrip() async throws {
        let fixture = try CursorFixtureHome()
        let adapter = fixture.adapter()
        let headers = try #require(fixture.value("composer.composerHeaders"))
        let backup = try Data(contentsOf: fixture.support.appendingPathComponent("User/globalStorage/state.vscdb.backup"))
        let untitledRows = fixture.count("bubbleId:\(IDs.untitled):") + fixture.count("checkpointId:\(IDs.untitled):")
        let total = fixture.count("")
        var plan = try await adapter.deletePlan(for: try await session(adapter, IDs.named), destination: .quarantine)

        let executor = fixture.executor()
        #expect(throws: ExecutorError.self) { try executor.execute(plan) } // not acknowledged
        #expect(fixture.count("composerData:\(IDs.named)") == 1)

        plan.isAcknowledged = true
        let sizeBefore = FileSystem.size(of: fixture.database)
        let entry = try executor.execute(plan)
        #expect(fixture.count("composerData:\(IDs.named)") == 0)
        #expect(fixture.count("bubbleId:\(IDs.named):") == 0)
        #expect(fixture.count("agentKv:\(IDs.named):") == 0)
        #expect(fixture.count("") == total - 8)
        #expect(fixture.count("bubbleId:\(IDs.untitled):") + fixture.count("checkpointId:\(IDs.untitled):") == untitledRows)
        #expect(fixture.count("agentKv:blob:") == 1) // shared rows stay
        #expect(fixture.count("composer.content.") == 1)
        #expect(fixture.value("composer.composerHeaders") == headers.replacingOccurrences(of: Self.namedHeader, with: ""))
        #expect(fixture.pragma("integrity_check") == "ok")
        // No VACUUM: the file keeps its size and the freed pages stay on the free list.
        #expect(FileSystem.size(of: fixture.database) >= sizeBefore)
        #expect((Int(fixture.pragma("freelist_count") ?? "") ?? 0) > 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.agentTranscript.path))
        #expect(try Data(contentsOf: fixture.support.appendingPathComponent("User/globalStorage/state.vscdb.backup")) == backup)
        #expect(entry.snapshots.contains { $0.original == fixture.database && $0.copy != nil })
        #expect(try await adapter.sessions().contains { $0.id == IDs.named } == false)

        _ = try executor.undo(entry)
        #expect(fixture.count("composerData:\(IDs.named)") == 1)
        #expect(fixture.count("bubbleId:\(IDs.named):") == 3)
        #expect(fixture.value("composer.composerHeaders") == headers)
        #expect(FileManager.default.fileExists(atPath: fixture.agentTranscript.path))
        #expect(try await adapter.sessions().contains { $0.id == IDs.named })
    }

    @Test("undo refuses once something wrote to the database again, and keeps the copy for purging")
    func undoRefusedAfterChange() async throws {
        let fixture = try CursorFixtureHome()
        let adapter = fixture.adapter()
        var plan = try await adapter.deletePlan(for: try await session(adapter, IDs.small), destination: .quarantine)
        plan.isAcknowledged = true
        let executor = fixture.executor()
        let entry = try executor.execute(plan)
        #expect(fixture.count("composerData:\(IDs.small)") == 0)

        try fixture.write("INSERT INTO ItemTable VALUES ('cursor/written-later', 'true');")
        #expect(throws: ExecutorError.self) { try executor.undo(entry) }
        #expect(fixture.value("cursor/written-later") == "true") // the newer database stays
        #expect(fixture.count("composerData:\(IDs.small)") == 0)
        let logged = try #require(try executor.undoLog.entries().first { $0.id == entry.id })
        #expect(logged.irreversible)
        #expect(try executor.purgePlan([.toolCopy]).items.contains { $0.entryID == entry.id })
    }

    @Test("a failed integrity check puts the copy back at once")
    func integrityFailureRestores() async throws {
        let fixture = try CursorFixtureHome()
        let adapter = fixture.adapter()
        let headers = fixture.value("composer.composerHeaders")
        var plan = try await adapter.deletePlan(for: try await session(adapter, IDs.named), destination: .quarantine)
        plan.isAcknowledged = true
        let executor = fixture.executor(integrity: FailingIntegrityChecker())
        #expect {
            try executor.execute(plan)
        } throws: { error in
            guard case ExecutorError.integrityCheckFailed(_, _, let restored) = error else { return false }
            return restored
        }
        #expect(fixture.count("composerData:\(IDs.named)") == 1)
        #expect(fixture.count("bubbleId:\(IDs.named):") == 3)
        #expect(fixture.value("composer.composerHeaders") == headers)
        #expect(FileManager.default.fileExists(atPath: fixture.agentTranscript.path)) // nothing moved either
        #expect(try executor.undoLog.latestPending() == nil)
    }

    @Test("Cursor running makes every editor chat live and blocks the delete; Apple's CursorUIViewService does not")
    func cursorRunning() async throws {
        let fixture = try CursorFixtureHome()
        let running = [RunningProcess(pid: 600, name: "Cursor"), RunningProcess(pid: 601, name: "Cursor Helper (Renderer)")]
        let adapter = fixture.adapter(running: running)
        let sessions = try await adapter.sessions()
        #expect(sessions.filter(CursorAdapter.isEditorChat).allSatisfy { $0.status == .live })
        #expect(sessions.first { $0.id == IDs.cli }?.status == .idle)
        let plan = try await adapter.deletePlan(for: try await session(adapter, IDs.named), destination: .quarantine)
        #expect(plan.liveCheck.isLive)
        #expect(plan.liveCheck.reasons.contains { $0.contains("one shared database") })
        #expect(throws: ExecutorError.self) { try fixture.executor(running: running).execute(plan) }
        #expect(fixture.count("composerData:\(IDs.named)") == 1)

        // Planned while quit, started before the user confirmed: the executor checks again.
        var quiet = try await fixture.adapter().deletePlan(for: try await session(fixture.adapter(), IDs.named), destination: .quarantine)
        quiet.isAcknowledged = true
        #expect(throws: ExecutorError.self) { try fixture.executor(running: running).execute(quiet) }
        #expect(fixture.count("composerData:\(IDs.named)") == 1)

        let apple = fixture.adapter(running: [RunningProcess(pid: 1346, name: "CursorUIViewService")])
        #expect(try await apple.sessions().allSatisfy { $0.status == .idle })
    }

    @Test("a process holding the database open blocks the plan and the executor")
    func openHandles() async throws {
        let fixture = try CursorFixtureHome()
        let holder = OpenHandleHolder(pid: 77, processName: "sqlite3", path: fixture.database.path)
        let blocked = try await fixture.adapter(holders: [holder]).deletePlan(for: try await session(fixture.adapter(), IDs.named))
        #expect(blocked.liveCheck.isLive)
        #expect(blocked.liveCheck.openHandles == .open)

        var plan = try await fixture.adapter().deletePlan(for: try await session(fixture.adapter(), IDs.named), destination: .quarantine)
        plan.isAcknowledged = true
        let executor = fixture.executor(openFiles: [77: [fixture.database.path]])
        #expect {
            try executor.execute(plan)
        } throws: { error in
            guard case ExecutorError.filesOpen = error else { return false }
            return true
        }
        #expect(fixture.count("composerData:\(IDs.named)") == 1)
        #expect(try executor.undoLog.entries().allSatisfy { $0.snapshots.isEmpty })
    }

    @Test("no clone, no edit: a failing copier leaves the database alone")
    func snapshotFailure() async throws {
        let fixture = try CursorFixtureHome()
        var plan = try await fixture.adapter().deletePlan(for: try await session(fixture.adapter(), IDs.named), destination: .quarantine)
        plan.isAcknowledged = true
        let failing = QuarantineCopier(clone: { _, _ in throw POSIXError(.ENOTSUP) }, copy: { _, _ in throw POSIXError(.ENOSPC) })
        let executor = Executor(storeRoot: fixture.storeRoot, processes: FixedProcessLister([]), copier: failing)
        #expect(throws: ExecutorError.self) { try executor.execute(plan) }
        #expect(fixture.count("composerData:\(IDs.named)") == 1)
    }

    @Test("an unknown chat list shape makes the adapter read-only for editor chats")
    func unknownHeaders() async throws {
        let fixture = try CursorFixtureHome()
        try fixture.write("UPDATE ItemTable SET value = '{\"composers\": 3}' WHERE key = 'composer.composerHeaders';")
        let adapter = fixture.adapter()
        guard case .readOnly = await adapter.status() else { Issue.record("expected read-only"); return }
        // CLI chats are folders and still work.
        let cli = try await session(adapter, IDs.cli)
        #expect(try await adapter.deletePlan(for: cli).moves.count == 1)
    }

    @Test("a chat also listed in a pre-3.0 workspace database is not deleted")
    func workspaceListing() async throws {
        let fixture = try CursorFixtureHome()
        let workspace = fixture.support.appendingPathComponent("User/workspaceStorage/9a8b7c6d/state.vscdb")
        try CodexFixtureHome.buildDatabase("""
            CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
            INSERT INTO ItemTable VALUES ('composer.composerData', '{"allComposers":[{"composerId":"\(IDs.small)"}]}');
            """, at: workspace)
        let adapter = fixture.adapter()
        let plan = try await adapter.deletePlan(for: try await session(adapter, IDs.small))
        #expect(plan.isEmpty)
        #expect(plan.remarks.first?.contains("workspace database") == true)
    }

    @Test("editor chats have no archive; CLI chats compress in place")
    func archive() async throws {
        let fixture = try CursorFixtureHome()
        let adapter = fixture.adapter()
        let editor = try await adapter.archivePlan(for: try await session(adapter, IDs.named))
        #expect(editor.isEmpty)
        #expect(editor.remarks.first?.contains("no file of it to compress") == true)
        let cli = try await adapter.archivePlan(for: try await session(adapter, IDs.cli))
        #expect(cli.compressions.map(\.file.lastPathComponent) == ["store.db"])
    }

    @Test("CLI chat delete moves the folder and undo puts it back")
    func cliDelete() async throws {
        let fixture = try CursorFixtureHome()
        let adapter = fixture.adapter()
        let plan = try await adapter.deletePlan(for: try await session(adapter, IDs.cli), destination: .quarantine)
        #expect(plan.moves.map(\.source) == [fixture.cliChat])
        #expect(plan.databaseEdits.isEmpty)
        #expect(plan.acknowledgement == nil)
        let executor = fixture.executor()
        let entry = try executor.execute(plan)
        #expect(!FileManager.default.fileExists(atPath: fixture.cliChat.path))
        #expect(fixture.count("composerData:") == 4) // the database is not touched
        _ = try executor.undo(entry)
        #expect(FileManager.default.fileExists(atPath: fixture.cliChat.appendingPathComponent("store.db").path))
    }

    @Test("the footprint links the chats database to Sessions and keeps Cursor's own steps")
    func footprint() async throws {
        let fixture = try CursorFixtureHome()
        let footprint = try await fixture.adapter().footprint()
        let chats = try #require(footprint.categories.first { $0.name == "Chats database" })
        #expect(chats.guidance == .manageInSessions)
        #expect(chats.advice == CursorFootprint.chatCleanupSteps)
        #expect(chats.note.hasPrefix("3 chats"))
        #expect(footprint.categories.first { $0.name == "CLI chats" }?.guidance == .manageInSessions)
    }
}

@Suite("JSON list cut")
struct JSONListCutTests {
    private func cut(_ text: String, field: String? = "allComposers", id: String) -> String? {
        JSONListCut.removing(from: Data(text.utf8), field: field, idField: "composerId", id: id).map { String(decoding: $0.data, as: UTF8.self) }
    }

    @Test("first, middle, last and only entries go with one comma; everything else stays")
    func positions() {
        let list = #"{"x": 1, "allComposers": [ {"composerId":"a","n":[1,2]} , {"composerId":"b","s":"}]\""},{"composerId":"c"} ], "y":"z"}"#
        #expect(cut(list, id: "a") == #"{"x": 1, "allComposers": [ {"composerId":"b","s":"}]\""},{"composerId":"c"} ], "y":"z"}"#)
        #expect(cut(list, id: "b") == #"{"x": 1, "allComposers": [ {"composerId":"a","n":[1,2]},{"composerId":"c"} ], "y":"z"}"#)
        #expect(cut(list, id: "c") == #"{"x": 1, "allComposers": [ {"composerId":"a","n":[1,2]} , {"composerId":"b","s":"}]\""} ], "y":"z"}"#)
        #expect(cut(#"{"allComposers":[{"composerId":"a"}]}"#, id: "a") == #"{"allComposers":[]}"#)
        #expect(cut(#"[{"composerId":"a"},{"composerId":"b"}]"#, field: nil, id: "b") == #"[{"composerId":"a"}]"#)
        #expect(cut(list, id: "zzz") == list)
        #expect(cut(#"{"other":[]}"#, id: "a") == nil)
    }
}
