import DomovyCore
import Foundation
import Testing

@Suite("Disk cleanups")
struct CleanupTests {
    private static let desktopApp = RunningProcess(pid: 501, name: "Claude")

    private static func relative(_ moves: [FileMove], _ fixture: CleanupFixtureHome) -> Set<String> {
        Set(moves.map { String($0.source.standardizedFileURL.path.dropFirst(fixture.home.standardizedFileURL.path.count + 1)) })
    }

    // MARK: Plan contents

    @Test("VM bundle: moves the bundle, states the consequence and what is not verified")
    func vmBundle() async throws {
        let fixture = try CleanupFixtureHome()
        let cleanup = try await fixture.planner().plan(.claudeDesktopVM)
        #expect(Self.relative(cleanup.plan.moves, fixture) == ["Library/Application Support/Claude/vm_bundles/claudevm.bundle"])
        #expect(cleanup.plan.destination == .trash)
        #expect(cleanup.hasConsequences)
        #expect(cleanup.plan.remarks.first == ClaudeDesktopFootprint.vmNote + " Domovy can put it back with Undo while it is still in the Trash.")
        #expect(cleanup.plan.remarks.contains { $0.hasPrefix("Not verified by Anthropic:") })
        #expect(cleanup.plan.mustNotBeRunning.map(\.appName) == ["Claude Desktop"])
        #expect(cleanup.canExecute)
        #expect(cleanup.summary.hasPrefix("Moves 1 folder ("))
    }

    @Test("Electron caches: three folders, safe, the summary says exactly what happens")
    func caches() async throws {
        let fixture = try CleanupFixtureHome()
        let cleanup = try await fixture.planner().plan(.claudeDesktopCaches, destination: .quarantine)
        let support = "Library/Application Support/Claude/"
        #expect(Self.relative(cleanup.plan.moves, fixture) == [support + "Cache", support + "Code Cache", support + "GraphiteDawnCache"])
        #expect(!cleanup.hasConsequences)
        #expect(cleanup.summary.hasPrefix("Moves 3 folders ("))
        #expect(cleanup.summary.hasSuffix(") to the Domovy quarantine folder. You can undo this."))
    }

    @Test("Codex logs: the database moves with its -wal and -shm files")
    func codexLogs() async throws {
        let fixture = try CleanupFixtureHome()
        let cleanup = try await fixture.planner().plan(.codexLogs)
        #expect(Self.relative(cleanup.plan.moves, fixture) == [".codex/logs_2.sqlite", ".codex/logs_2.sqlite-wal", ".codex/logs_2.sqlite-shm"])
        #expect(cleanup.summary.hasPrefix("Moves 3 files ("))
        #expect(cleanup.plan.mustNotBeRunning.first?.scope == fixture.codex.standardizedFileURL)
    }

    @Test("a cleanup with nothing on disk is reported, not planned")
    func missing() async throws {
        let fixture = try CleanupFixtureHome()
        try FileManager.default.removeItem(at: fixture.url(".claude/security/agent-sdk-venv"))
        await #expect(throws: CleanupError.notFound(.claudeCodeAgentSDK)) { try await fixture.planner().plan(.claudeCodeAgentSDK) }
    }

    // MARK: Refusals

    @Test("Claude Desktop running blocks its cleanups, naming the app and pid; the claude CLI does not")
    func desktopRunning() async throws {
        let fixture = try CleanupFixtureHome()
        for id in [CleanupID.claudeDesktopVM, .claudeDesktopCaches] {
            let blocked = try await fixture.planner(running: [Self.desktopApp]).plan(id)
            #expect(blocked.isBlocked)
            #expect(blocked.plan.liveCheck.reasons.first?.hasPrefix("Claude Desktop is running (Claude, pid 501).") == true)
            #expect(blocked.summary.hasPrefix("Nothing will change yet."))
            await #expect(throws: CleanupError.self) { try await fixture.planner().execute(blocked, with: fixture.executor()) }
        }
        let cli = try await fixture.planner(running: [RunningProcess(pid: 77, name: "claude")]).plan(.claudeDesktopCaches)
        #expect(!cli.isBlocked)

        // Desktop started after the plan: the executor checks again and changes nothing.
        let plan = try await fixture.planner().plan(.claudeDesktopCaches, destination: .quarantine)
        #expect(throws: ExecutorError.self) { try fixture.executor(running: [Self.desktopApp]).execute(plan.plan) }
        #expect(fixture.exists("Library/Application Support/Claude/Cache"))
    }

    @Test("Codex logs are blocked only by a Codex process using this CODEX_HOME")
    func codexRunning() async throws {
        let fixture = try CleanupFixtureHome()
        let codex = RunningProcess(pid: 610, name: "codex")
        let here = fixture.url(".codex/state_5.sqlite").standardizedFileURL.path
        let blocked = try await fixture.planner(running: [codex], openFiles: [610: [here]]).plan(.codexLogs)
        #expect(blocked.isBlocked)
        #expect(blocked.plan.liveCheck.reasons.first?.contains("(pid 610)") == true)
        let elsewhere = try await fixture.planner(running: [codex], openFiles: [610: ["/Users/someone/.codex/state_5.sqlite"]]).plan(.codexLogs)
        #expect(!elsewhere.isBlocked)
    }

    @Test("Agent SDK venv: an open file inside it blocks, and so does an open-file check that cannot run")
    func venvOpenFiles() async throws {
        let fixture = try CleanupFixtureHome()
        let inside = fixture.url(".claude/security/agent-sdk-venv/lib/site.py").standardizedFileURL.path
        let holder = OpenHandleHolder(pid: 812, processName: "python3", path: inside)
        let blocked = try await fixture.planner(holders: [holder]).plan(.claudeCodeAgentSDK)
        #expect(blocked.isBlocked)
        #expect(blocked.plan.liveCheck.reasons == ["python3 (pid 812) has a file open in agent-sdk-venv."])

        let unsure = try await fixture.planner(holders: nil).plan(.claudeCodeAgentSDK)
        #expect(unsure.isBlocked)

        // Opened after the plan was shown: execute checks again.
        let plan = try await fixture.planner().plan(.claudeCodeAgentSDK, destination: .quarantine)
        await #expect(throws: CleanupError.inUse(reasons: ["python3 (pid 812) has a file open in agent-sdk-venv."])) {
            try await fixture.planner(holders: [holder]).execute(plan, with: fixture.executor())
        }
        #expect(fixture.exists(".claude/security/agent-sdk-venv/lib/site.py"))
    }

    // MARK: Keep rows

    @Test("keep rows never have a cleanup, and no cleanup moves anything a keep row covers")
    func keepRowsNeverPlanned() async throws {
        let fixture = try CleanupFixtureHome()
        try fixture.sparse(".codex/sessions/2026/11/21/rollout-2026-11-21T10-00-00-01a1f066-6666-7666-8666-666666666666.jsonl", bytes: 101_000_000)
        let providers: [any FootprintProvider] = [ClaudeCodeAdapter(home: fixture.home), CodexAdapter(home: fixture.home)] + FootprintScanner.measuredOnly(home: fixture.home)
        let footprints = await FootprintScanner.scan(providers).footprints
        var keep: [String] = []
        var ids: [CleanupID] = []
        for category in footprints.flatMap(\.categories) {
            if category.disposition == .keep {
                #expect(category.cleanupID == nil, "\(category.name)")
                keep += (category.items.isEmpty ? [category.url] : category.items).map(\.standardizedFileURL.path)
            } else if let id = category.cleanupID {
                ids.append(id)
            }
        }
        #expect(Set(ids).isSuperset(of: [.claudeDesktopVM, .claudeDesktopCaches, .claudeCodeAgentSDK, .codexLogs, .codexLargeRollouts]))
        for id in ids {
            let plan = try await fixture.planner().plan(id).plan
            for path in plan.moves.map(\.source.standardizedFileURL.path) + plan.compressions.map(\.file.standardizedFileURL.path) {
                #expect(!keep.contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }, "\(id.rawValue) touches \(path)")
            }
        }
    }

    // MARK: Undo

    @Test("undo puts every folder back with its modification time")
    func undoRoundTrip() async throws {
        let fixture = try CleanupFixtureHome()
        let cache = "Library/Application Support/Claude/Cache"
        let old = Date(timeIntervalSince1970: 1_760_000_000)
        try fixture.setDate(cache + "/Cache_Data/data_0", old)
        try fixture.setDate(cache, old)
        let planner = fixture.planner()
        let executor = fixture.executor()
        let cleanup = try await planner.plan(.claudeDesktopCaches, destination: .quarantine)

        let entry = try await planner.execute(cleanup, with: executor)
        #expect(entry.sessionID == CleanupID.claudeDesktopCaches.rawValue)
        #expect(entry.moved.count == 3)
        #expect(!fixture.exists(cache))
        for item in entry.moved {
            #expect(item.current.path.hasPrefix(executor.quarantineDirectory.path))
        }
        let moved = try #require(entry.moved.first { $0.original.lastPathComponent == "Cache" })
        #expect((try moved.current.appendingPathComponent("Cache_Data/data_0").resourceValues(forKeys: [.contentModificationDateKey])).contentModificationDate == old)

        _ = try executor.undo(entry)
        #expect(fixture.exists(cache + "/Cache_Data/data_0"))
        #expect(fixture.exists("Library/Application Support/Claude/Code Cache"))
        #expect(fixture.modificationDate(cache + "/Cache_Data/data_0") == old)
        #expect(fixture.modificationDate(cache) == old)
        // The footprint is back to what it was.
        let footprint = try await ClaudeDesktopFootprint(home: fixture.home).footprint()
        #expect(footprint.categories.first { $0.name == "Electron caches" }?.items.count == 3)
    }

    // MARK: Large rollouts

    @Test("large rollouts: plain ones are compressed in place, .zst and open ones are left with a reason")
    func largeRollouts() async throws {
        let fixture = try CleanupFixtureHome()
        let day = ".codex/sessions/2026/11/21/"
        let plain = day + "rollout-2026-11-21T10-00-00-01a1f066-6666-7666-8666-666666666666.jsonl"
        let zst = day + "rollout-2026-11-21T11-00-00-01a1f077-7777-7777-8777-777777777777.jsonl.zst"
        let open = day + "rollout-2026-11-21T12-00-00-01a1f088-8888-7888-8888-888888888888.jsonl"
        for file in [plain, zst, open] { try fixture.sparse(file, bytes: 101_000_000) }
        let holder = OpenHandleHolder(pid: 640, processName: "codex", path: fixture.url(open).standardizedFileURL.path)

        let cleanup = try await fixture.planner(holders: [holder]).plan(.codexLargeRollouts)
        #expect(cleanup.plan.action == .archive)
        #expect(cleanup.plan.moves.isEmpty)
        #expect(cleanup.plan.compressions.map(\.file.lastPathComponent) == [URL(fileURLWithPath: plain).lastPathComponent])
        #expect(cleanup.plan.compressions.first?.modificationTime != nil)
        let reasons = Dictionary(uniqueKeysWithValues: cleanup.excluded.map { ($0.url.lastPathComponent, $0.reason) })
        #expect(reasons[URL(fileURLWithPath: zst).lastPathComponent] == "Already compressed by Codex (zstd).")
        #expect(reasons[URL(fileURLWithPath: open).lastPathComponent] == "codex (pid 640) has it open.")
        #expect(!cleanup.isBlocked)
        #expect(cleanup.summary.hasPrefix("Compresses 1 rollout in place"))
    }

    // MARK: Worktrees

    @Test("worktrees: clean and merged ones move; dirty, unmerged and unknown folders stay with a reason")
    func worktrees() async throws {
        let fixture = try CleanupFixtureHome()
        let repo = try fixture.makeRepository()
        let base = ".codex/worktrees/"
        for id in ["1f2e", "7c9a", "4b4b"] {
            try fixture.git(["worktree", "add", "-q", "--detach", fixture.url(base + id + "/orbit-api").path, "main"], in: repo)
        }
        try fixture.write(base + "7c9a/orbit-api/README.md", "work in progress\n")
        let unmerged = fixture.url(base + "4b4b/orbit-api")
        try fixture.git(["switch", "-q", "-c", "codex/experiment"], in: unmerged)
        try fixture.write(base + "4b4b/orbit-api/idea.txt", "idea\n")
        try fixture.git(["add", "idea.txt"], in: unmerged)
        try fixture.git(["commit", "-q", "-m", "Try an idea"], in: unmerged)
        try fixture.write(base + "9d9d/scratch/notes.txt")
        let before = fixture.modificationDate(base + "1f2e/orbit-api/README.md")

        let cleanup = try await fixture.planner().plan(.codexWorktrees, destination: .quarantine)
        #expect(Self.relative(cleanup.plan.moves, fixture) == [base + "1f2e/orbit-api"])
        #expect(cleanup.plan.moves.first?.note == "Clean; its commits are on main.")
        let reasons = Dictionary(uniqueKeysWithValues: cleanup.excluded.map { (String($0.url.path.split(separator: "/").suffix(2).joined(separator: "/")), $0.reason) })
        #expect(reasons["7c9a/orbit-api"] == "Has uncommitted changes (1 file).")
        #expect(reasons["4b4b/orbit-api"] == "Has commits that are on no other branch.")
        #expect(reasons["9d9d/scratch"] == "Not a git worktree Domovy recognises. Left alone.")
        #expect(cleanup.plan.remarks.contains { $0.contains("git worktree prune") })
        #expect(try fixture.git(["status", "--porcelain"], in: fixture.url(base + "7c9a/orbit-api")).isEmpty == false, "the dirty worktree is untouched")

        let executor = fixture.executor()
        let entry = try await fixture.planner().execute(cleanup, with: executor)
        #expect(!fixture.exists(base + "1f2e/orbit-api"))
        #expect(fixture.exists(base + "7c9a/orbit-api/README.md"))
        #expect(fixture.exists(base + "4b4b/orbit-api/idea.txt"))
        _ = try executor.undo(entry)
        #expect(fixture.modificationDate(base + "1f2e/orbit-api/README.md") == before)
        #expect(try fixture.git(["status", "--porcelain"], in: fixture.url(base + "1f2e/orbit-api")).isEmpty, "git still knows the worktree after undo")
    }

    @Test("worktrees: one in use stays, and a running Codex in this home blocks")
    func worktreeInUse() async throws {
        let fixture = try CleanupFixtureHome()
        let repo = try fixture.makeRepository()
        let worktree = fixture.url(".codex/worktrees/1f2e/orbit-api")
        try fixture.git(["worktree", "add", "-q", "--detach", worktree.path, "main"], in: repo)
        let holder = OpenHandleHolder(pid: 700, processName: "node", path: worktree.appendingPathComponent("README.md").standardizedFileURL.path)
        let inUse = try await fixture.planner(holders: [holder]).plan(.codexWorktrees)
        #expect(inUse.plan.moves.isEmpty)
        #expect(inUse.excluded.first?.reason == "In use: node (pid 700) has a file open in it.")

        let codex = RunningProcess(pid: 610, name: "codex")
        let blocked = try await fixture.planner(running: [codex], openFiles: [610: [worktree.appendingPathComponent("README.md").standardizedFileURL.path]]).plan(.codexWorktrees)
        #expect(blocked.isBlocked)
    }
}
