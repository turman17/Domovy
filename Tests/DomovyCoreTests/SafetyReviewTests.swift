@testable import DomovyCore
import Darwin
import Foundation
import Testing

/// A tool command that deletes some of what it was asked to and then fails.
private struct PartlyDeletingRunner: CommandRunner {
    let victims: [URL]

    func run(_ command: PlannedCommand) throws -> CommandResult {
        for victim in victims { try? FileManager.default.removeItem(at: victim) }
        return CommandResult(status: 1, errorOutput: "disk I/O error")
    }
}

/// Appends one line to an index file the first `times` it is called, the way a running agent
/// would between Domovy's read and its swap, and remembers the file's mtime afterwards.
private final class Appender: @unchecked Sendable {
    let line: String
    private let lock = NSLock()
    private var left: Int
    private(set) var mtimeAfter: FileTime?

    init(_ line: String, times: Int = 1) {
        self.line = line
        self.left = times
    }

    func append(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard left > 0, let handle = try? FileHandle(forWritingTo: url) else { return }
        left -= 1
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
        try? handle.close()
        mtimeAfter = FileSystem.modificationTime(of: IndexFileRewrite.resolved(url))
    }
}

@Suite("Safety review: failures, races, purge and scope")
struct SafetyReviewTests {
    typealias IDs = FixtureHome.ClaudeCode
    static let project = "-Users-dev-code-orbit-api"
    static let clear = LiveCheckResult(isLive: false, reasons: [], checkedSignals: [], openHandles: .clear)

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("domovy-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func quarantineFiles(_ executor: Executor) -> [URL] {
        let all = FileManager.default.enumerator(at: executor.quarantineDirectory, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return all.filter { !FileSystem.isDirectory($0) }
    }

    // MARK: 1. A permanent command that fails half way

    /// `models/` holds a manifest and a folder of two layers; the tool deletes the manifest and
    /// one layer, then fails.
    private func modelStore() throws -> (root: URL, store: URL, manifest: URL, layers: URL, plan: Plan) {
        let base = try temporaryFolder()
        let root = base.appendingPathComponent("models", isDirectory: true)
        let layers = root.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: layers, withIntermediateDirectories: true)
        let manifest = root.appendingPathComponent("manifest")
        try Data("manifest".utf8).write(to: manifest)
        try Data("layer a".utf8).write(to: layers.appendingPathComponent("a.bin"))
        try Data("layer b".utf8).write(to: layers.appendingPathComponent("b.bin"))
        let command = PlannedCommand(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: ["rm", "model"], note: "Runs rm.",
                                     copiesBeforeRun: [manifest, layers], verifications: [.fileGone(manifest)], isPermanent: true)
        let plan = Plan(agent: .ollama, sessionID: "model", action: .delete, destination: nil, moves: [], indexEdits: [],
                        commands: [command], liveCheck: Self.clear, scope: [root])
        return (root, base.appendingPathComponent("store", isDirectory: true), manifest, layers, plan)
    }

    @Test("a permanent command that deletes part and fails: copies are kept, the error says so, undo restores all")
    func failedCommandKeepsCopies() throws {
        let (_, store, manifest, layers, plan) = try modelStore()
        let executor = Executor(storeRoot: store, runner: PartlyDeletingRunner(victims: [manifest, layers.appendingPathComponent("a.bin")]),
                                processes: FixedProcessLister([]))
        do {
            _ = try executor.execute(plan)
            Issue.record("the failed command must be reported")
        } catch {
            #expect(!error.localizedDescription.contains("left as they were"))
            #expect(error.localizedDescription.contains("undo puts them back"))
        }
        let entry = try #require(try executor.undoLog.entries().first)
        #expect(entry.failure != nil)
        #expect(entry.moved.count == 2)
        #expect(entry.hasChangesToUndo)

        _ = try executor.undo(entry)
        #expect(try String(contentsOf: manifest, encoding: .utf8) == "manifest")
        #expect(try String(contentsOf: layers.appendingPathComponent("a.bin"), encoding: .utf8) == "layer a")
        #expect(try String(contentsOf: layers.appendingPathComponent("b.bin"), encoding: .utf8) == "layer b")
    }

    @Test("a permanent command that deletes and then times out: the copy is kept and undo restores it")
    func timedOutCommandKeepsCopies() throws {
        let (root, store, manifest, _, original) = try modelStore()
        let script = root.deletingLastPathComponent().appendingPathComponent("slow-rm")
        try Data("#!/bin/sh\nrm -f \"$1\"\nexec sleep 30\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let command = PlannedCommand(executable: script, arguments: [manifest.path], note: "Runs slow-rm.",
                                     copiesBeforeRun: [manifest], verifications: [.fileGone(manifest)], isPermanent: true)
        let plan = Plan(agent: .ollama, sessionID: "model", action: .delete, destination: nil, moves: [], indexEdits: [],
                        commands: [command], liveCheck: original.liveCheck, scope: original.scope)
        let executor = Executor(storeRoot: store, runner: ProcessCommandRunner(timeout: 1), processes: FixedProcessLister([]))
        #expect(throws: ExecutorError.self) { try executor.execute(plan) }
        #expect(!FileManager.default.fileExists(atPath: manifest.path))
        let entry = try #require(try executor.undoLog.entries().first)
        #expect(entry.moved.count == 1)
        _ = try executor.undo(entry)
        #expect(try String(contentsOf: manifest, encoding: .utf8) == "manifest")
    }

    @Test("a command that fails without touching anything says its files were left as they were")
    func failedCommandLeftAlone() throws {
        let (_, store, _, _, plan) = try modelStore()
        let executor = Executor(storeRoot: store, runner: PartlyDeletingRunner(victims: []), processes: FixedProcessLister([]))
        #expect { try executor.execute(plan) } throws: { $0.localizedDescription.contains("left as they were") }
        #expect(quarantineFiles(executor).isEmpty)
    }

    // MARK: 2. A file opened between plan and execute

    /// The idle transcript grown past the size ditto compresses, and a session full of secrets.
    private func secretsFixture() throws -> FixtureHome {
        let fixture = try FixtureHome()
        try fixture.appendSyntheticLines(to: ArchiveTests.transcriptPath, kilobytes: 64)
        let flagged = RedactionTests.flagged
        try Data(RedactionTests.transcript().utf8).write(to: fixture.transcript(flagged, project: Self.project))
        return fixture
    }

    @Test("delete, archive and redact refuse when a process opened the session's file after the plan, or when that cannot be checked")
    func openedAfterPlan() async throws {
        let fixture = try secretsFixture()
        let adapter = fixture.adapter()
        let idle = try await adapter.session(matching: IDs.idle)
        let transcript = fixture.transcript(IDs.idle, project: Self.project)
        let held = FixedProcessLister([], openFiles: [77: [transcript.standardizedFileURL.path]])
        let unsure = FixedProcessLister([], unreadable: [78])

        let delete = try await adapter.deletePlan(for: idle, destination: .quarantine)
        for lister in [held, unsure] {
            #expect(throws: ExecutorError.self) { try Executor(storeRoot: fixture.storeRoot, processes: lister).execute(delete) }
            #expect(FileManager.default.fileExists(atPath: transcript.path))
        }

        let archive = try await adapter.archivePlan(for: idle)
        try #require(archive.compressions.contains { $0.file == transcript.standardizedFileURL })
        for lister in [held, unsure] {
            #expect(throws: ExecutorError.self) { try Executor(storeRoot: fixture.storeRoot, processes: lister).execute(archive) }
            #expect(!APFSCompression.isCompressed(transcript))
        }

        let flagged = try await adapter.session(matching: RedactionTests.flagged)
        let report = try await SecretScanner().scan(flagged, adapter: adapter)
        let redact = try await RedactionPlanner.plan(for: flagged, findings: report.findings, adapter: adapter)
        let file = try #require(redact.redactions.first?.file)
        let before = try Data(contentsOf: file)
        let holder = FixedProcessLister([], openFiles: [79: [file.path]])
        #expect(throws: ExecutorError.self) { try Executor(storeRoot: fixture.storeRoot, processes: holder).execute(redact) }
        #expect(try Data(contentsOf: file) == before)
        #expect(try Executor(storeRoot: fixture.storeRoot, processes: holder).undoLog.entries().allSatisfy { !$0.hasChangesToUndo })
    }

    @Test("a real writer holding the transcript open stops an archive; nothing it appends is lost")
    func realWriterStopsArchive() async throws {
        let fixture = try secretsFixture()
        let adapter = fixture.adapter()
        let transcript = fixture.transcript(IDs.idle, project: Self.project)
        let plan = try await adapter.archivePlan(for: try await adapter.session(matching: IDs.idle))
        try #require(!plan.compressions.isEmpty)

        let writer = Process()
        writer.executableURL = URL(fileURLWithPath: "/bin/sh")
        writer.arguments = ["-c", "exec 3>>\"$0\"; exec sleep 30", transcript.path]
        try writer.run()
        defer { writer.terminate() }
        var seen = false
        for _ in 0..<100 where !seen {
            seen = LibprocProcessLister().holders(of: [transcript])?.contains { $0.pid == writer.processIdentifier } == true
            if !seen { usleep(20_000) }
        }
        try #require(seen, "the writer holds the transcript open")

        #expect(throws: ExecutorError.self) { try Executor(storeRoot: fixture.storeRoot).execute(plan) }
        #expect(!APFSCompression.isCompressed(transcript))
    }

    @Test("the libproc snapshots can inspect every running process of this user")
    func snapshotsAvailable() {
        #expect(LibprocOpenHandleChecker.takeSnapshot() != nil)
        #expect(LibprocOpenHandleChecker.takeMappedSnapshot() != nil)
        #expect(LibprocOpenHandleChecker.isOwnRunningProcess(getpid()))
        #expect(!LibprocOpenHandleChecker.isOwnRunningProcess(1), "launchd belongs to root")
    }

    // MARK: 3. Agents appending to a shared index while Domovy rewrites it

    private func historyLines(_ fixture: FixtureHome, session: String) throws -> Int {
        try fixture.contents("history.jsonl").split(separator: "\n").filter { $0.contains("\"\(session)\"") }.count
    }

    @Test("removing and reinserting history lines keeps lines appended meanwhile, the newer mtime, the symlink and xattrs")
    func concurrentAppendToHistory() async throws {
        let fixture = try FixtureHome()
        let history = fixture.claudeDirectory.appendingPathComponent("history.jsonl")
        let real = fixture.claudeDirectory.appendingPathComponent("history-real.jsonl")
        try FileManager.default.moveItem(at: history, to: real)
        try FileManager.default.createSymbolicLink(at: history, withDestinationURL: real)
        #expect(setxattr(real.path, "com.example.domovy-test", "kept", 4, 0, 0) == 0)
        let idleLines = try historyLines(fixture, session: IDs.idle)
        try #require(idleLines > 0)

        let adapter = fixture.adapter()
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.idle), destination: .quarantine)
        var executor = fixture.executor()
        let first = Appender(HistorySecretsTests.historyLine("appended during the delete", session: IDs.live))
        executor.indexRewriteHook = { first.append($0) }
        let entry = try executor.execute(plan)
        #expect(try historyLines(fixture, session: IDs.idle) == 0)
        #expect(try fixture.contents("history.jsonl").contains("appended during the delete"))
        #expect(FileSystem.modificationTime(of: real) == first.mtimeAfter)

        let second = Appender(HistorySecretsTests.historyLine("appended during the undo", session: IDs.live))
        executor.indexRewriteHook = { second.append($0) }
        _ = try executor.undo(entry)
        let text = try fixture.contents("history.jsonl")
        #expect(try historyLines(fixture, session: IDs.idle) == idleLines)
        #expect(text.contains("appended during the delete") && text.contains("appended during the undo"))
        #expect(FileSystem.modificationTime(of: real) == second.mtimeAfter, "undo does not move the mtime back over the append")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: history.path)) != nil, "history.jsonl is still a symlink")
        #expect(getxattr(real.path, "com.example.domovy-test", nil, 0, 0, 0) == 4)
    }

    @Test("line-level redaction keeps a line appended meanwhile; an index that never stops changing is left alone")
    func concurrentAppendDuringRedaction() async throws {
        let fixture = try FixtureHome()
        let history = fixture.claudeDirectory.appendingPathComponent("history.jsonl")
        let handle = try FileHandle(forWritingTo: history)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((HistorySecretsTests.historyLine("use \(SecretSamples.openAI) here", session: IDs.idle) + "\n").utf8))
        try handle.close()
        let adapter = fixture.adapter()
        let session = try await adapter.session(matching: IDs.idle)
        let report = try await SecretScanner().scan(session, adapter: adapter)
        let plan = try await RedactionPlanner.plan(for: session, findings: report.findings.filter { $0.file == history }, adapter: adapter)
        try #require(plan.redactions.first?.isLineLevel == true)

        var restless = fixture.executor()
        let always = Appender(HistorySecretsTests.historyLine("busy", session: IDs.live), times: 100)
        restless.indexRewriteHook = { always.append($0) }
        #expect(throws: ExecutorError.self) { try restless.execute(plan) }
        #expect(try fixture.contents("history.jsonl").contains(SecretSamples.openAI), "left as it is")
        #expect(try fixture.contents("history.jsonl").components(separatedBy: "\"busy\"").count - 1 == IndexFileRewrite.attempts)

        var executor = fixture.executor()
        let once = Appender(HistorySecretsTests.historyLine("appended during the redaction", session: IDs.live))
        executor.indexRewriteHook = { once.append($0) }
        _ = try executor.execute(plan)
        let text = try fixture.contents("history.jsonl")
        #expect(!text.contains(SecretSamples.openAI))
        #expect(text.contains("appended during the redaction"))
    }

    // MARK: 4. Purge leaves no plaintext secret behind

    @Test("delete a flagged session, redact another, purge: no plaintext secret is left anywhere under the store")
    func purgeLeavesNoSecret() async throws {
        let fixture = try secretsFixture()
        let history = fixture.claudeDirectory.appendingPathComponent("history.jsonl")
        let handle = try FileHandle(forWritingTo: history)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((HistorySecretsTests.historyLine("use \(SecretSamples.openAI) for the eval", session: IDs.idle) + "\n").utf8))
        try handle.close()
        let adapter = fixture.adapter()
        let executor = fixture.executor()

        let idle = try await adapter.session(matching: IDs.idle)
        var delete = try await adapter.deletePlan(for: idle, destination: .quarantine)
        delete.secretFindingCount = 1
        let deleted = try executor.execute(delete)
        #expect(!deleted.indexRestores.isEmpty)

        let flagged = try await adapter.session(matching: RedactionTests.flagged)
        let report = try await SecretScanner().scan(flagged, adapter: adapter)
        _ = try executor.execute(try await RedactionPlanner.plan(for: flagged, findings: report.findings, adapter: adapter))

        // An unflagged delete keeps working: its backups are not offered and undo still works.
        let other = try await adapter.session(matching: IDs.expiring)
        let kept = try executor.execute(try await adapter.deletePlan(for: other, destination: .quarantine))

        try executor.purge(try executor.purgePlan())
        let secrets = [SecretSamples.openAI, SecretSamples.aws, SecretSamples.github]
        let files = FileManager.default.enumerator(at: fixture.storeRoot, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for file in files where !FileSystem.isDirectory(file) {
            let text = String(decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self)
            for secret in secrets { #expect(!text.contains(secret), "\(file.lastPathComponent) still holds a secret") }
        }
        for entry in try executor.undoLog.entries() where entry.originalsPurgedAt != nil {
            let lines = entry.indexRestores.flatMap(\.removedLines).map { String(decoding: $0.bytes, as: UTF8.self) }
            #expect(!lines.contains { line in secrets.contains { line.contains($0) } })
        }
        _ = try executor.undo(kept)
        #expect(FileManager.default.fileExists(atPath: other.transcriptURL.path))
    }

    // MARK: 5. Scope: plans never reach outside the agent's folders; stale undo is refused

    private func requireScoped(_ plan: Plan, adapter: any AgentAdapter, home: URL) {
        if !plan.changedFiles.isEmpty { #expect(!plan.scope.isEmpty, "\(adapter.kind) plan has no scope") }
        for url in plan.changedFiles { #expect(Executor.isInside(url, plan.scope), "\(adapter.kind): \(url.path) outside its scope") }
        for folder in plan.scope {
            #expect(adapter.scope.map(\.standardizedFileURL).contains(folder))
            #expect(FileSystem.relativePath(of: folder, under: home) != nil)
        }
    }

    private func requireAllScoped(_ adapter: any AgentAdapter, home: URL) async throws {
        for session in try await adapter.sessions() {
            if let plan = try? await adapter.deletePlan(for: session, destination: .quarantine) { requireScoped(plan, adapter: adapter, home: home) }
            if let plan = try? await adapter.archivePlan(for: session) { requireScoped(plan, adapter: adapter, home: home) }
        }
    }

    @Test("every adapter's plans stay inside the adapter's folders")
    func adaptersStayInScope() async throws {
        let claude = try FixtureHome()
        try claude.installDesktop()
        try await requireAllScoped(claude.adapter(), home: claude.home)
        let codex = try CodexFixtureHome()
        try await requireAllScoped(codex.adapter(), home: codex.home)
        let cursor = try CursorFixtureHome()
        try await requireAllScoped(cursor.adapter(), home: cursor.home)
        let gemini = try GeminiFixtureHome()
        try await requireAllScoped(gemini.adapter(), home: gemini.home)
        let copilot = try CopilotFixtureHome()
        try await requireAllScoped(copilot.adapter(), home: copilot.home)
        let openCode = try OpenCodeFixtureHome()
        try await requireAllScoped(openCode.adapter(), home: openCode.home)
    }

    @Test("the executor refuses a plan path outside its scope, and a plan with no scope")
    func executorRefusesOutsideScope() throws {
        let base = try temporaryFolder()
        let root = base.appendingPathComponent("agent", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("projects"), withIntermediateDirectories: true)
        let outside = base.appendingPathComponent("Documents/notes.txt")
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: outside)
        let crafted = root.appendingPathComponent("projects/../../Documents/notes.txt")
        let executor = Executor(storeRoot: base.appendingPathComponent("store"), processes: FixedProcessLister([]))
        for scope in [[root], []] {
            let plan = Plan(agent: .openCode, sessionID: "../../Documents/notes", action: .delete, destination: .quarantine,
                            moves: [FileMove(source: crafted, kind: .file, sizeBytes: 4, note: "Session diff")], indexEdits: [],
                            liveCheck: Self.clear, scope: scope)
            #expect { try executor.execute(plan) } throws: { error in
                guard case ExecutorError.outsideScope = error else { return false }
                return true
            }
            #expect(FileManager.default.fileExists(atPath: outside.path))
        }
        #expect(try executor.undoLog.entries().isEmpty)
    }

    @Test("ids from an agent's database that look like paths or options are refused")
    func craftedIDsRefused() async throws {
        let openCode = try OpenCodeFixtureHome()
        let crafted = ["../../../../Documents/x", "-rf", "a/b"]
        for (n, id) in crafted.enumerated() {
            try CodexFixtureHome.buildDatabase("""
                INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated)
                VALUES ('\(id)', 'prj_orbit', NULL, 'crafted-\(n)', '/Users/dev/code/orbit-api', 'Crafted \(n)', '1.18.30', 1795000000000, 1795000000000);
                """, at: openCode.database)
        }
        let target = openCode.url("storage/session_diff/../../../../Documents/x.json")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: target)
        let adapter = openCode.adapter()
        for id in crafted {
            guard let session = try await adapter.sessions().first(where: { $0.id == id }) else { continue }
            await #expect(throws: AdapterError.self) { try await adapter.deletePlan(for: session) }
        }
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(openCode.stubInvocations().isEmpty)

        let cursor = try CursorFixtureHome()
        try CodexFixtureHome.buildDatabase("INSERT INTO cursorDiskKV VALUES ('composerData:\(CursorFixtureHome.IDs.named):other', '{}');", at: cursor.database)
        let cursorAdapter = cursor.adapter()
        let named = try #require(try await cursorAdapter.sessions().first { $0.id == CursorFixtureHome.IDs.named })
        await #expect(throws: AdapterError.self) { try await cursorAdapter.deletePlan(for: named) }
        #expect(!SafeID.isSafe("-rf") && !SafeID.isSafe("../x") && !SafeID.isSafe("a:b") && SafeID.isSafe(CursorFixtureHome.IDs.named))
    }

    @Test("undo of an entry already undone or purged on disk is refused, even from a stale copy")
    func staleUndoRefused() async throws {
        let fixture = try secretsFixture()
        let adapter = fixture.adapter()
        let executor = fixture.executor()
        let idleLines = try historyLines(fixture, session: IDs.idle)
        let stale = try executor.execute(try await adapter.deletePlan(for: try await adapter.session(matching: IDs.idle), destination: .quarantine))
        _ = try executor.undo(stale)
        #expect { try executor.undo(stale) } throws: { error in
            guard case ExecutorError.alreadyUndone = error else { return false }
            return true
        }
        #expect(try historyLines(fixture, session: IDs.idle) == idleLines, "lines are put back once")

        var flagged = try await adapter.deletePlan(for: try await adapter.session(matching: RedactionTests.flagged), destination: .quarantine)
        flagged.secretFindingCount = 3
        let purgedLater = try executor.execute(flagged)
        try executor.purge(try executor.purgePlan([.flaggedSession]))
        #expect { try executor.undo(purgedLater) } throws: { error in
            guard case ExecutorError.originalsPurged = error else { return false }
            return true
        }
    }

    // MARK: Worktrees and cross-volume moves

    @Test("a clean worktree that holds files git ignores is kept")
    func worktreeWithIgnoredFilesKept() throws {
        let fixture = try CleanupFixtureHome()
        let repo = try fixture.makeRepository()
        try fixture.write("code/orbit-api/.gitignore", ".env\n")
        _ = try fixture.git(["add", ".gitignore"], in: repo)
        _ = try fixture.git(["commit", "-q", "-m", "Ignore .env"], in: repo)
        let worktree = fixture.url(".codex/worktrees/1f2e/orbit-api")
        _ = try fixture.git(["worktree", "add", "-q", "--detach", worktree.path, "main"], in: repo)
        #expect(GitWorktreeInspector().inspect(worktree) == .removable("Clean; its commits are on main."))
        try fixture.write(".codex/worktrees/1f2e/orbit-api/.env", "API_KEY=local\n")
        guard case .keep(let reason) = GitWorktreeInspector().inspect(worktree) else {
            Issue.record("a worktree with ignored files must be kept")
            return
        }
        #expect(reason.contains("git ignores"))
    }

    @Test("a move by copy checks the copy, keeps mtimes, then removes the source")
    func moveByCopy() throws {
        let base = try temporaryFolder()
        let source = base.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("transcript".utf8).write(to: source.appendingPathComponent("sub/t.jsonl"))
        let time = FileTime(seconds: 1_795_000_000, nanoseconds: 7)
        try FileSystem.setModificationTime(time, of: source.appendingPathComponent("sub/t.jsonl"))
        let target = base.appendingPathComponent("copy", isDirectory: true)
        let executor = Executor(storeRoot: base.appendingPathComponent("store"), processes: FixedProcessLister([]))
        try executor.moveAcrossVolumes(source, to: target)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try String(contentsOf: target.appendingPathComponent("sub/t.jsonl"), encoding: .utf8) == "transcript")
        #expect(FileSystem.modificationTime(of: target.appendingPathComponent("sub/t.jsonl")) == time)
    }
}
