import DomovyCore
import Foundation
import Testing

/// Leftover agent worktrees and build output, on throwaway git repositories made in a temp home.
@Suite("Leftover checkouts and build output")
struct LeftoverTests {
    /// A temp home with `code/orbit-api` (main checkout) and agent worktrees of it.
    final class Home: Sendable {
        let base: URL
        let home: URL
        let repo: URL
        var store: URL { base.appendingPathComponent("store", isDirectory: true) }

        init() throws {
            let fm = FileManager.default
            let temp = fm.temporaryDirectory.appendingPathComponent("domovy-leftover-tests-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            base = temp.standardizedFileURL
            home = base.appendingPathComponent("home", isDirectory: true)
            repo = home.appendingPathComponent("code/orbit-api", isDirectory: true)
            try write("code/orbit-api/README.md", "# orbit-api\n")
            try write("code/orbit-api/package.json", "{}\n")
            try write("code/orbit-api/.gitignore", "node_modules/\n.env\ndist/\n")
            try git(["init", "-q", "-b", "main"], in: repo)
            try git(["add", "."], in: repo)
            try git(["commit", "-q", "-m", "Initial commit"], in: repo)
        }

        deinit { try? FileManager.default.removeItem(at: base) }

        func url(_ relative: String) -> URL { home.appendingPathComponent(relative) }
        func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: url(relative).path) }

        func write(_ relative: String, _ text: String = "synthetic\n") throws {
            let file = url(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }

        static let gitEnvironment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]

        @discardableResult
        func git(_ arguments: [String], in folder: URL) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-c", "user.name=Dev", "-c", "user.email=dev@example.invalid", "-c", "commit.gpgsign=false", "-C", folder.path] + arguments
            process.environment = Self.gitEnvironment.merging(["HOME": home.path, "PATH": "/usr/bin:/bin"]) { a, _ in a }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed"])
            }
            return String(decoding: data, as: UTF8.self)
        }

        /// `git worktree add` on a new branch.
        @discardableResult
        func worktree(_ relative: String, branch: String) throws -> URL {
            let folder = url(relative)
            try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            try git(["worktree", "add", "-q", "-b", branch, folder.path, "main"], in: repo)
            return folder
        }

        func scanner(cwd: [OpenHandleHolder]? = [], open: [OpenHandleHolder]? = []) -> LeftoverScanner {
            let git = GitReader(git: URL(fileURLWithPath: "/usr/bin/git"), environment: Self.gitEnvironment)
            return LeftoverScanner(home: home, git: git, openHandles: PrefixOpenHandleChecker(holders: open), workingDirectories: FixedWorkingDirectoryLister(cwd))
        }

        func executor() -> Executor {
            Executor(storeRoot: store, processes: FixedProcessLister([]))
        }

        func session(_ id: String, in relative: String, agent: AgentKind = .claudeCode, status: Session.Status = .idle) -> Session {
            Session(id: id, agent: agent, title: "Synthetic", projectPath: url(relative).path, lastActive: Date(), sizeBytes: 1,
                    status: status, expiresAt: nil, transcriptURL: url(".claude/projects/x/\(id).jsonl"))
        }
    }

    /// The common layout: a clean Claude Code worktree, a dirty one, a Codex worktree with only
    /// node_modules in it, one with an `.env`, and the user's own worktree no agent touched.
    private func standardHome() throws -> (Home, [Session]) {
        let home = try Home()
        try home.worktree("code/orbit-api/.claude/worktrees/tidy", branch: "worktree-tidy")
        try home.worktree("code/orbit-api/.claude/worktrees/busy", branch: "worktree-busy")
        try home.write("code/orbit-api/.claude/worktrees/busy/README.md", "# changed\n")
        try home.worktree(".codex/worktrees/1f2e/orbit-api", branch: "codex-1f2e")
        try home.write(".codex/worktrees/1f2e/orbit-api/node_modules/left-pad/index.js", "module.exports = 1\n")
        try home.worktree(".codex/worktrees/9a8b/orbit-api", branch: "codex-9a8b")
        try home.write(".codex/worktrees/9a8b/orbit-api/.env", "API_KEY=local\n")
        try home.worktree("code/orbit-api-mine", branch: "mine")
        try home.write("code/orbit-api/node_modules/react/index.js", "module.exports = 2\n")
        let sessions = [home.session("s1", in: "code/orbit-api"), home.session("s2", in: "code/orbit-api/.claude/worktrees/tidy")]
        return (home, sessions)
    }

    private func worktree(_ report: LeftoverReport, _ home: Home, _ relative: String) -> AgentWorktree? {
        report.worktrees.first { $0.url.path == home.url(relative).path }
    }

    @Test("finds agent worktrees by folder and session, never the user's own; reads git only")
    func scanStates() async throws {
        let (home, sessions) = try standardHome()
        let headsBefore = try home.git(["for-each-ref", "--format=%(refname)"], in: home.repo)
        let report = await home.scanner().scan(sessions: sessions)
        #expect(report.groups.count == 1)
        #expect(report.groups.first?.name == "orbit-api")

        let tidy = try #require(worktree(report, home, "code/orbit-api/.claude/worktrees/tidy"))
        #expect(tidy.agent == .claudeCode && tidy.branch == "worktree-tidy" && tidy.sessionCount == 1)
        #expect(tidy.state == .leftover("Clean. Branch worktree-tidy (merged into main) stays in the repository."))

        let busy = try #require(worktree(report, home, "code/orbit-api/.claude/worktrees/busy"))
        guard case .hasWork(let reason) = busy.state else { Issue.record("a dirty worktree must not be a leftover"); return }
        #expect(reason.contains("1 uncommitted change (README.md)"))

        let codex = try #require(worktree(report, home, ".codex/worktrees/1f2e/orbit-api"))
        #expect(codex.agent == .codex && codex.isLeftover, "node_modules is rebuildable, so it does not keep the worktree")
        let env = try #require(worktree(report, home, ".codex/worktrees/9a8b/orbit-api"))
        guard case .hasWork(let envReason) = env.state else { Issue.record("an .env must keep the worktree"); return }
        #expect(envReason.contains(".env"))

        #expect(worktree(report, home, "code/orbit-api-mine") == nil, "a worktree no agent touched is the user's")
        #expect(try home.git(["for-each-ref", "--format=%(refname)"], in: home.repo) == headsBefore)
    }

    @Test("build output: ignored and untracked only, named with its explanation; main checkout unticked by default")
    func buildOutput() async throws {
        let (home, sessions) = try standardHome()
        // A tracked dist/ is part of the sources; an untracked, ignored dist/ is build output.
        try home.write("code/orbit-api/packages/web/package.json", "{}\n")
        try home.write("code/orbit-api/packages/web/dist/app.js", "tracked\n")
        try home.git(["add", "-f", "packages"], in: home.repo)
        try home.git(["commit", "-q", "-m", "Track dist"], in: home.repo)
        try home.write("code/orbit-api/packages/api/package.json", "{}\n")
        try home.write("code/orbit-api/packages/api/dist/server.js", "built\n")
        try home.write("code/orbit-api/target/debug/app", "not rust: no Cargo.toml\n")
        try home.write("code/orbit-api/.claude/worktrees/busy/node_modules/x/index.js", "1\n")
        let report = await home.scanner().scan(sessions: sessions)
        let outputs = report.buildOutputs
        let paths = Set(outputs.map { String($0.url.path.dropFirst(home.home.path.count + 1)) })
        #expect(paths == ["code/orbit-api/node_modules", "code/orbit-api/packages/api/dist", "code/orbit-api/.claude/worktrees/busy/node_modules"])
        let main = try #require(outputs.first { $0.url.lastPathComponent == "node_modules" && $0.isInMainCheckout })
        #expect(main.kind.explanation.contains("install puts them back"))
        let selected = Set(report.defaultSelection.map(\.path))
        #expect(!selected.contains(main.url.path))
        #expect(selected.contains(home.url("code/orbit-api/.claude/worktrees/busy/node_modules").path))
        #expect(!selected.contains(home.url("code/orbit-api/.claude/worktrees/busy").path))
    }

    @Test("a plain project folder: only unambiguous build output, one level down; the home folder is never scanned")
    func plainFolder() async throws {
        let home = try Home()
        try home.write("notes/node_modules/a/index.js", "1\n")
        try home.write("notes/dist/out.js", "1\n")
        try home.write("notes/deep/node_modules/b/index.js", "1\n")
        try home.write("node_modules/c/index.js", "1\n")
        let report = await home.scanner().scan(sessions: [home.session("p", in: "notes"), home.session("h", in: "")])
        #expect(report.buildOutputs.map(\.url.path) == [home.url("notes/node_modules").path])
    }

    @Test("plan, execute and undo: worktrees and build output move, branches and the main repository stay")
    func planExecuteUndo() async throws {
        let (home, sessions) = try standardHome()
        let scanner = home.scanner()
        let report = await scanner.scan(sessions: sessions)
        let gitDirBefore = try FileManager.default.contentsOfDirectory(atPath: home.repo.appendingPathComponent(".git").path).sorted()
        let leftover = await scanner.plan(report.defaultSelection, in: report, sessions: sessions, destination: .quarantine)
        let moved = Set(leftover.plan.moves.map { String($0.source.path.dropFirst(home.home.path.count + 1)) })
        #expect(moved == ["code/orbit-api/.claude/worktrees/tidy", ".codex/worktrees/1f2e/orbit-api"])
        #expect(leftover.canExecute && leftover.hasConsequences && leftover.plan.acknowledgement == nil)
        #expect(leftover.plan.remarks.contains { $0.contains("git worktree prune") })
        #expect(leftover.summary.hasPrefix("Moves 2 folders ("))

        let entry = try await scanner.execute(leftover, with: home.executor())
        #expect(!home.exists("code/orbit-api/.claude/worktrees/tidy") && !home.exists(".codex/worktrees/1f2e/orbit-api"))
        #expect(home.exists("code/orbit-api/.claude/worktrees/busy/README.md") && home.exists("code/orbit-api/node_modules/react/index.js"))
        #expect(try home.git(["branch", "--list", "worktree-tidy"], in: home.repo).contains("worktree-tidy"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.repo.appendingPathComponent(".git").path).sorted() == gitDirBefore)

        _ = try home.executor().undo(entry)
        #expect(home.exists("code/orbit-api/.claude/worktrees/tidy/README.md"))
        #expect(try home.git(["status", "--porcelain"], in: home.url("code/orbit-api/.claude/worktrees/tidy")).isEmpty, "the restored worktree works again")
    }

    @Test("a worktree with work only it holds moves only when asked for, and only after an explicit OK")
    func dirtyNeedsAcknowledgement() async throws {
        let (home, sessions) = try standardHome()
        let scanner = home.scanner()
        let report = await scanner.scan(sessions: sessions)
        let busy = home.url("code/orbit-api/.claude/worktrees/busy")
        let without = await scanner.plan([busy], in: report, sessions: sessions, destination: .quarantine)
        #expect(without.plan.moves.isEmpty)
        #expect(without.excluded.first?.reason.contains("uncommitted") == true)

        var with = await scanner.plan([], includingWork: [busy], in: report, sessions: sessions, destination: .quarantine)
        #expect(with.plan.moves.map(\.source.path) == [busy.path])
        #expect(with.worktreesWithWork.map(\.path) == [busy.path])
        #expect(with.plan.acknowledgement?.contains("once the Trash is emptied") == true)
        #expect(!with.canExecute)
        await #expect(throws: ExecutorError.self) { try await scanner.execute(with, with: home.executor()) }
        #expect(home.exists("code/orbit-api/.claude/worktrees/busy/README.md"))
        with.plan.isAcknowledged = true
        _ = try await scanner.execute(with, with: home.executor())
        #expect(!home.exists("code/orbit-api/.claude/worktrees/busy"))
    }

    @Test("live sessions, processes working inside and open files keep a folder; unsure blocks the plan")
    func liveChecks() async throws {
        let (home, initial) = try standardHome()
        var sessions = initial
        sessions.append(home.session("live", in: ".codex/worktrees/1f2e/orbit-api", agent: .codex, status: .live))
        let tidy = home.url("code/orbit-api/.claude/worktrees/tidy")
        let shell = OpenHandleHolder(pid: 4242, processName: "zsh", path: tidy.appendingPathComponent("src").path)
        let report = await home.scanner(cwd: [shell]).scan(sessions: sessions)
        #expect(worktree(report, home, ".codex/worktrees/1f2e/orbit-api")?.state == .inUse("A Codex session is live here."))
        #expect(worktree(report, home, "code/orbit-api/.claude/worktrees/tidy")?.state == .inUse("zsh (pid 4242) is working in tidy."))

        // Clear when planned, then a shell starts working in it before the move: refused.
        let clear = await home.scanner().scan(sessions: Array(sessions.dropLast()))
        let plan = await home.scanner().plan(clear.defaultSelection, in: clear, sessions: Array(sessions.dropLast()), destination: .quarantine)
        #expect(plan.canExecute)
        await #expect(throws: CleanupError.self) { try await home.scanner(cwd: [shell]).execute(plan, with: home.executor()) }
        #expect(home.exists("code/orbit-api/.claude/worktrees/tidy/README.md"))

        let editor = OpenHandleHolder(pid: 77, processName: "Code Helper", path: home.url("code/orbit-api/node_modules/react/index.js").path)
        let main = home.url("code/orbit-api/node_modules")
        let open = await home.scanner(open: [editor]).plan([main], in: clear, sessions: sessions, destination: .quarantine)
        #expect(open.plan.moves.isEmpty && open.excluded.first?.reason == "Code Helper (pid 77) has a file open in it.")

        let unsure = await home.scanner(cwd: nil).plan(clear.defaultSelection, in: clear, sessions: sessions, destination: .quarantine)
        #expect(unsure.isBlocked && !unsure.canExecute)
    }
}
