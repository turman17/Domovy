import DomovyCore
import Foundation
import Testing

@Suite("Executor")
struct ExecutorTests {
    typealias IDs = FixtureHome.ClaudeCode

    private func idlePlan(_ fixture: FixtureHome, destination: Destination = .quarantine) async throws -> Plan {
        let adapter = fixture.adapter()
        let session = try await adapter.session(matching: IDs.idle)
        return try await adapter.deletePlan(for: session, destination: destination)
    }

    @Test("quarantine move and undo round trip restores every file and history line")
    func roundTrip() async throws {
        let fixture = try FixtureHome()
        let historyBefore = try fixture.contents("history.jsonl")
        let historyMtime = try #require(fixture.modificationDate("history.jsonl"))
        let transcriptPath = "projects/-Users-dev-code-orbit-api/\(IDs.idle).jsonl"
        let transcriptMtime = try #require(fixture.modificationDate(transcriptPath))

        let plan = try await idlePlan(fixture)
        let executor = fixture.executor()
        let entry = try executor.execute(plan)

        #expect(entry.moved.count == plan.moves.count)
        #expect(entry.indexRestores.count == 1)
        #expect(entry.failure == nil)
        for move in plan.moves {
            #expect(!FileManager.default.fileExists(atPath: move.source.path), "\(move.source.lastPathComponent) should be gone")
        }
        for item in entry.moved {
            #expect(FileManager.default.fileExists(atPath: item.current.path))
            #expect(item.current.path.hasPrefix(executor.quarantineDirectory.path))
        }
        // Untouched neighbours stay.
        #expect(fixture.exists("projects/-Users-dev-code-orbit-api/memory/MEMORY.md"))
        #expect(fixture.exists("projects/-Users-dev-code-orbit-api/\(IDs.live).jsonl"))
        #expect(fixture.exists("settings.json"))

        // history.jsonl lost exactly the two lines of this session and kept its mtime.
        let historyAfter = try fixture.contents("history.jsonl")
        let remaining = historyAfter.split(separator: "\n")
        #expect(remaining.count == 4)
        #expect(!historyAfter.contains(IDs.idle))
        #expect(historyAfter.contains(IDs.live))
        #expect(historyAfter.hasSuffix("\n"))
        #expect(fixture.modificationDate("history.jsonl") == historyMtime)

        // The undo log has the entry and a byte-exact backup.
        let pending = try #require(try executor.undoLog.latestPending())
        #expect(pending.id == entry.id)
        let backup = try #require(entry.indexRestores.first?.backup)
        #expect(try String(contentsOf: backup, encoding: .utf8) == historyBefore)

        // Undo.
        let undone = try executor.undoLatest()
        #expect(undone.isUndone)
        for move in plan.moves {
            #expect(FileManager.default.fileExists(atPath: move.source.path), "\(move.source.lastPathComponent) should be back")
        }
        #expect(try fixture.contents("history.jsonl") == historyBefore)
        #expect(fixture.modificationDate("history.jsonl") == historyMtime)
        #expect(fixture.modificationDate(transcriptPath) == transcriptMtime)
        #expect(fixture.exists("file-history/\(IDs.idle)/8bc4437f0c9227b4@v2"))
        #expect(try executor.undoLog.latestPending() == nil)

        // The session is listed again as if nothing happened.
        let sessions = try await fixture.adapter().sessions()
        #expect(sessions.contains { $0.id == IDs.idle })

        #expect(throws: ExecutorError.self) { try executor.undoLatest() }
    }

    @Test("refuses to execute a plan for a live session")
    func refusesLive() async throws {
        let fixture = try FixtureHome()
        let adapter = fixture.adapter()
        let session = try await adapter.session(matching: IDs.live)
        let plan = try await adapter.deletePlan(for: session, destination: .quarantine)
        #expect(plan.liveCheck.isLive)
        #expect(plan.summary.hasPrefix("This session is live"))

        let executor = fixture.executor()
        let error = #expect(throws: ExecutorError.self) { try executor.execute(plan) }
        guard case .sessionIsLive(let reasons)? = error else {
            Issue.record("expected sessionIsLive, got \(String(describing: error))")
            return
        }
        #expect(reasons.first?.contains("pid 4242") == true)
        #expect(error?.localizedDescription.contains("nothing was changed") == true)
        #expect(fixture.exists("projects/-Users-dev-code-orbit-api/\(IDs.live).jsonl"))
        #expect(try executor.undoLog.entries().isEmpty)
    }

    @Test("index edit re-matches lines appended after planning and preserves them")
    func indexEditIsRobust() async throws {
        let fixture = try FixtureHome()
        let plan = try await idlePlan(fixture)

        // Claude Code appends while the plan sits in a preview sheet.
        let history = fixture.claudeDirectory.appendingPathComponent("history.jsonl")
        let handle = try FileHandle(forWritingTo: history)
        try handle.seekToEnd()
        let appended = "{\"display\":\"Later prompt\",\"pastedContents\":{},\"timestamp\":1,\"project\":\"/Users/dev/code/x\",\"sessionId\":\"ffffffff-6666-4666-8666-666666666666\"}\n"
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()

        let executor = fixture.executor()
        _ = try executor.execute(plan)
        let after = try fixture.contents("history.jsonl")
        #expect(after.split(separator: "\n").count == 5)
        #expect(after.contains("Later prompt"))
        #expect(!after.contains(IDs.idle))

        _ = try executor.undoLatest()
        let restored = try fixture.contents("history.jsonl")
        #expect(restored.split(separator: "\n").count == 7)
        #expect(restored.contains("Later prompt"))
        #expect(restored.split(separator: "\n")[0].contains(IDs.idle))
        #expect(restored.split(separator: "\n")[2].contains(IDs.idle))
    }

    @Test("undo stops and reports when something now occupies the original path")
    func undoConflict() async throws {
        let fixture = try FixtureHome()
        let plan = try await idlePlan(fixture)
        let executor = fixture.executor()
        let entry = try executor.execute(plan)

        let transcript = fixture.claudeDirectory.appendingPathComponent("projects/-Users-dev-code-orbit-api/\(IDs.idle).jsonl")
        try Data("{}\n".utf8).write(to: transcript)

        let error = #expect(throws: ExecutorError.self) { try executor.undo(entry) }
        guard case .restoreFailed(let url, _)? = error else {
            Issue.record("expected restoreFailed")
            return
        }
        #expect(url.standardizedFileURL.path == transcript.standardizedFileURL.path, "\(url.path)")
        // Still pending: the user can resolve the conflict and undo again.
        #expect(try executor.undoLog.latestPending()?.id == entry.id)
    }
}
