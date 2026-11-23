import DomovyCore
import Foundation
import Testing

/// Executes Codex plans against a fixture home with the stub CLI. Never the real `codex`.
@Suite("Codex plans executed")
struct CodexExecutorTests {
    typealias IDs = CodexFixtureHome.IDs

    @Test("codex delete runs, is verified, and undo puts rollouts and index lines back")
    func cliDeleteRoundTrip() async throws {
        let fixture = try CodexFixtureHome()
        let indexBefore = try fixture.contents("session_index.jsonl")
        let historyBefore = try fixture.contents("history.jsonl")
        let rolloutMtime = try #require(fixture.modificationDate(CodexFixtureHome.idleRollout))
        let adapter = fixture.adapter()
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.idle))
        let executor = fixture.executor()

        let entry = try executor.execute(plan)
        #expect(fixture.stubInvocations().last == "delete --force \(IDs.idle)")
        #expect(entry.leftovers.isEmpty, "\(entry.leftovers)")
        #expect(!fixture.exists(CodexFixtureHome.idleRollout))
        #expect(!fixture.exists(CodexFixtureHome.idleSegment))
        #expect(!fixture.exists("generated_images/\(IDs.idle)"))
        #expect(try !fixture.contents("session_index.jsonl").contains(IDs.idle))
        #expect(try !fixture.contents("history.jsonl").contains(IDs.idle))
        #expect(fixture.rowCount("state_5.sqlite", "SELECT count(*) FROM threads WHERE id = '\(IDs.idle)'") == 0)
        // Copies of what codex deleted, the moved images folder, and two index restores.
        #expect(entry.moved.count == 3)
        #expect(entry.indexRestores.map(\.file.lastPathComponent).sorted() == ["history.jsonl", "session_index.jsonl"])
        // Neighbours stay.
        #expect(fixture.exists(CodexFixtureHome.liveRollout))
        #expect(fixture.exists("auth.json") && fixture.exists("config.toml"))

        _ = try executor.undo(entry)
        #expect(fixture.exists(CodexFixtureHome.idleRollout))
        #expect(fixture.exists(CodexFixtureHome.idleSegment))
        #expect(fixture.exists("generated_images/\(IDs.idle)/ig_0001.png"))
        #expect(fixture.modificationDate(CodexFixtureHome.idleRollout) == rolloutMtime)
        #expect(try fixture.contents("session_index.jsonl") == indexBefore)
        #expect(try fixture.contents("history.jsonl") == historyBefore)
    }

    @Test("what codex delete leaves behind is reported")
    func cliDeleteLeftovers() async throws {
        let fixture = try CodexFixtureHome()
        fixture.touch(".stub-sloppy")
        let adapter = fixture.adapter()
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.idle))
        let entry = try fixture.executor().execute(plan)
        #expect(!fixture.exists(CodexFixtureHome.idleRollout))
        #expect(entry.leftovers.contains("2 lines stay in session_index.jsonl."))
        #expect(entry.leftovers.contains("1 row stays in state_5.sqlite (threads)."))
        #expect(entry.leftovers.contains("2 rows stay in thread_history_1.sqlite (thread_items)."))
    }

    @Test("a failing codex command changes nothing and keeps no copies")
    func cliFailure() async throws {
        let fixture = try CodexFixtureHome()
        fixture.touch(".stub-fail")
        let adapter = fixture.adapter()
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.idle))
        let executor = fixture.executor()
        #expect {
            try executor.execute(plan)
        } throws: { error in
            guard case ExecutorError.commandFailed(let line, let status, let message) = error else { return false }
            return line == "codex delete --force \(IDs.idle)" && status == 1 && message.contains("failed to delete")
        }
        #expect(fixture.exists(CodexFixtureHome.idleRollout))
        #expect(fixture.exists("generated_images/\(IDs.idle)"))
        #expect(try fixture.contents("history.jsonl").contains(IDs.idle))
        let quarantined = (try? FileManager.default.subpathsOfDirectory(atPath: executor.quarantineDirectory.path)) ?? []
        #expect(!quarantined.contains { $0.contains("rollout") })
    }

    @Test("fallback delete moves files, edits session_index.jsonl with a backup, and never writes SQLite")
    func fallbackDelete() async throws {
        let fixture = try CodexFixtureHome()
        let indexBefore = try fixture.contents("session_index.jsonl")
        let stateBefore = try Data(contentsOf: fixture.url("state_5.sqlite"))
        let adapter = fixture.adapter(cli: CodexCLI.Choice.none)
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.idle), destination: .quarantine)
        let executor = fixture.executor()
        let entry = try executor.execute(plan)

        #expect(fixture.stubInvocations().isEmpty)
        #expect(!fixture.exists(CodexFixtureHome.idleRollout))
        #expect(try fixture.contents("session_index.jsonl").split(separator: "\n").count == 1)
        #expect(try Data(contentsOf: fixture.url("state_5.sqlite")) == stateBefore)
        #expect(entry.moved.allSatisfy { $0.current.path.hasPrefix(executor.quarantineDirectory.path) })

        _ = try executor.undo(entry)
        #expect(fixture.exists(CodexFixtureHome.idleRollout))
        #expect(try fixture.contents("session_index.jsonl") == indexBefore)
    }

    @Test("codex archive moves the rollout to archived_sessions; undo runs codex unarchive")
    func cliArchiveRoundTrip() async throws {
        let fixture = try CodexFixtureHome()
        let adapter = fixture.adapter()
        let plan = try await adapter.archivePlan(for: try await adapter.session(matching: IDs.idle))
        let executor = fixture.executor()
        let entry = try executor.execute(plan)
        #expect(entry.leftovers.isEmpty, "\(entry.leftovers)")
        #expect(!fixture.exists(CodexFixtureHome.idleRollout))
        #expect(fixture.exists("archived_sessions/rollout-2026-11-20T09-15-00-\(IDs.idle).jsonl"))
        #expect(entry.undoCommands.map(\.arguments) == [["unarchive", IDs.idle]])
        let listed = try await adapter.sessions().first { $0.id == IDs.idle }
        #expect(listed?.status == .archived)

        _ = try executor.undo(entry)
        #expect(fixture.stubInvocations().last == "unarchive \(IDs.idle)")
        #expect(fixture.exists(CodexFixtureHome.idleRollout))
    }

    @Test("the executor checks again that Codex is quit right before running")
    func executorRechecksRunningCodex() async throws {
        let fixture = try CodexFixtureHome()
        let adapter = fixture.adapter()
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.idle))
        #expect(!plan.liveCheck.isLive)
        #expect {
            try fixture.executor(running: [RunningProcess(pid: 4_321, name: "Codex")]).execute(plan)
        } throws: { error in
            guard case ExecutorError.appRunning(let reasons) = error else { return false }
            return reasons.first?.hasPrefix("Codex is running") == true
        }
        #expect(fixture.exists(CodexFixtureHome.idleRollout))
        #expect(!fixture.stubInvocations().contains { $0.hasPrefix("delete") })
    }
}
