@testable import DomovyCore
import Foundation
import Testing

/// Claude Desktop's registry of Claude Code sessions, on a fixture copy that mirrors the
/// schema verified on a real install (synthetic values).
@Suite("Claude Desktop registry")
struct DesktopRegistryTests {
    typealias IDs = FixtureHome.ClaudeCode
    typealias Desktop = FixtureHome.Desktop

    private func fixture() throws -> FixtureHome {
        let fixture = try FixtureHome()
        try fixture.installDesktop()
        return fixture
    }

    @Test("entries are read from <id>/<id>/local_*.json; markers and scheduled tasks are ignored")
    func snapshot() throws {
        let fixture = try fixture()
        let snapshot = ClaudeDesktopRegistry(directory: fixture.registryDirectory).snapshot()
        #expect(snapshot.status == .ready)
        #expect(snapshot.entries.count == 4)
        let first = try #require(snapshot.entries.first { $0.file == fixture.registryFile(Desktop.idleEntry) })
        #expect(first.desktopID == "local_5e1d2f3a-0000-4000-8000-000000000001")
        #expect(first.cliSessionID == IDs.idle)
        #expect(first.title == "Fix flaky orbit-api test")
        #expect(!first.isArchived)
        #expect(snapshot.byCLISessionID[IDs.expiring]?.count == 2)
    }

    @Test("Claude Code sessions link to their Desktop entry: title, archived flag, agent label")
    func linking() async throws {
        let fixture = try fixture()
        let sessions = try await fixture.adapter().sessions()
        let idle = try #require(sessions.first { $0.id == IDs.idle })
        #expect(idle.desktop?.file == fixture.registryFile(Desktop.idleEntry))
        #expect(idle.title == "Fix flaky orbit-api test")
        #expect(idle.agentLabel == "Claude Code \u{00B7} Desktop")
        // Two entries: the newest wins.
        let expiring = try #require(sessions.first { $0.id == IDs.expiring })
        #expect(expiring.desktop?.file == fixture.registryFile(Desktop.expiringNewer))
        #expect(expiring.desktop?.isArchived == false)
        let live = try #require(sessions.first { $0.id == IDs.live })
        #expect(live.desktop == nil)
        #expect(live.agentLabel == "Claude Code")

        let artifacts = try await fixture.adapter().artifacts(of: idle)
        let entry = try #require(artifacts.first { $0.url == fixture.registryFile(Desktop.idleEntry) })
        #expect(entry.kind == .indexEntry)
        #expect(entry.note == "Desktop registry entry, file removed")
    }

    @Test("delete plan takes the registry entry off Desktop's list and requires Desktop to be quit")
    func deletePlanIncludesEntry() async throws {
        let fixture = try fixture()
        let adapter = fixture.adapter()
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.idle), destination: .quarantine)
        #expect(plan.registryRemovals.map(\.file) == [fixture.registryFile(Desktop.idleEntry)])
        #expect(plan.registryRemovals.first?.note == "Desktop registry entry, file removed")
        #expect(plan.indexEdits.map(\.file.lastPathComponent) == ["history.jsonl"])
        #expect(plan.mustNotBeRunning == [ClaudeDesktopRegistry.processMatcher])
        #expect(!plan.liveCheck.isLive)
        #expect(plan.summary.contains("takes 1 entry off Claude Desktop's session list"))
    }

    @Test("a running Claude Desktop blocks the plan and the executor; the claude CLI does not")
    func runningDesktopRefuses() async throws {
        let fixture = try fixture()
        let desktop = [RunningProcess(pid: 501, name: "Claude"), RunningProcess(pid: 502, name: "Claude Helper (Renderer)")]
        let blocked = fixture.adapter(desktopProcesses: FixedProcessLister(desktop))
        let plan = try await blocked.deletePlan(for: try await blocked.session(matching: IDs.idle), destination: .quarantine)
        #expect(plan.liveCheck.isLive)
        #expect(plan.liveCheck.reasons.contains { $0.contains("Quit Claude Desktop to change its session list.") })
        #expect(throws: ExecutorError.self) { try fixture.executor(running: desktop).execute(plan) }
        #expect(FileManager.default.fileExists(atPath: fixture.registryFile(Desktop.idleEntry).path))

        // The CLI is called `claude`; only the app's `Claude` counts.
        let cli = fixture.adapter(desktopProcesses: FixedProcessLister([RunningProcess(pid: 503, name: "claude")]))
        let open = try await cli.deletePlan(for: try await cli.session(matching: IDs.idle), destination: .quarantine)
        #expect(!open.liveCheck.isLive)

        // Started after the plan was made: the executor checks again.
        #expect(throws: ExecutorError.self) { try fixture.executor(running: [desktop[1]]).execute(open) }
    }

    @Test("executing backs the entry up with its mtime; undo puts it back exactly")
    func backupAndUndo() async throws {
        let fixture = try fixture()
        let file = fixture.registryFile(Desktop.idleEntry)
        let bytes = try Data(contentsOf: file)
        let mtime = try #require(FileSystem.modificationTime(of: file))
        let adapter = fixture.adapter()
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.idle), destination: .quarantine)
        let executor = fixture.executor()

        let entry = try executor.execute(plan)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let restore = try #require(entry.registryRestores.first)
        #expect(try Data(contentsOf: restore.backup) == bytes)
        #expect(FileSystem.modificationTime(of: restore.backup) == mtime)
        #expect(FileSystem.relativePath(of: restore.backup, under: fixture.storeRoot) != nil)
        // Neighbours stay.
        #expect(FileManager.default.fileExists(atPath: fixture.registryFile(Desktop.orphanEntry).path))

        _ = try executor.undo(entry)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(FileSystem.modificationTime(of: file) == mtime)
        #expect(fixture.exists("projects/-Users-dev-code-orbit-api/\(IDs.idle).jsonl"))
    }

    @Test("undo restores from the backup when the moved entry is gone")
    func undoFromBackup() async throws {
        let fixture = try fixture()
        let file = fixture.registryFile(Desktop.idleEntry)
        let bytes = try Data(contentsOf: file)
        let adapter = fixture.adapter()
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.idle), destination: .quarantine)
        let executor = fixture.executor()
        let entry = try executor.execute(plan)
        try FileManager.default.removeItem(at: try #require(entry.registryRestores.first).current)

        _ = try executor.undo(entry)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test("an entry in an unknown place makes the registry read-only; the plan leaves it and says why")
    func unknownLayoutIsReadOnly() async throws {
        let fixture = try fixture()
        let stray = fixture.registryDirectory.appendingPathComponent("local_stray.json")
        try Data("{}".utf8).write(to: stray)
        let snapshot = ClaudeDesktopRegistry(directory: fixture.registryDirectory).snapshot()
        guard case .readOnly(let reason) = snapshot.status else {
            Issue.record("expected read-only, got \(snapshot.status)")
            return
        }
        #expect(reason.contains("Domovy leaves the list as it is"))

        let adapter = fixture.adapter()
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.idle), destination: .quarantine)
        #expect(plan.registryRemovals.isEmpty)
        #expect(plan.mustNotBeRunning.isEmpty)
        #expect(plan.remarks.contains { $0.contains("Claude Desktop still lists this session") })
    }

    @Test("an entry that now names another session is left alone")
    func entryChangedSincePlan() async throws {
        let fixture = try fixture()
        let adapter = fixture.adapter()
        let plan = try await adapter.deletePlan(for: try await adapter.session(matching: IDs.idle), destination: .quarantine)
        try fixture.editRegistry(Desktop.idleEntry) { $0["cliSessionId"] = IDs.live }
        let entry = try fixture.executor().execute(plan)
        #expect(entry.registryRestores.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.registryFile(Desktop.idleEntry).path))
    }
}
