@testable import DomovyCore
import Foundation
import Testing

@Suite("Orphan finder")
struct OrphanTests {
    typealias IDs = FixtureHome.ClaudeCode
    typealias Desktop = FixtureHome.Desktop
    static let orphanID = "eeeeeeee-5555-4555-8555-555555555555"
    static let freshID = "12345678-aaaa-4bbb-8ccc-1234567890ab"
    static let priorID = "99999999-9999-4999-8999-999999999999"
    static let project = "-Users-dev-code-orbit-api"

    /// Fixture with Desktop, an old orphan companion and a fresh one (inside the grace period).
    private func fixture(now: Date = Date()) throws -> FixtureHome {
        let fixture = try FixtureHome(now: now)
        try fixture.installDesktop(now: now)
        let fm = FileManager.default
        for (id, age) in [(Self.orphanID, 5 * 86_400.0), (Self.freshID, 60.0)] {
            let folder = fixture.claudeDirectory.appendingPathComponent("file-history/\(id)", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 7, count: 2048).write(to: folder.appendingPathComponent("snapshot@v1"))
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: folder.path)
        }
        return fixture
    }

    private func setDate(_ fixture: FixtureHome, _ relative: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fixture.claudeDirectory.appendingPathComponent(relative).path)
    }

    @Test("orphans: old companions and Desktop entries without a transcript; fresh ones wait an hour")
    func report() async throws {
        let now = Date()
        let fixture = try fixture(now: now)
        // A Desktop entry written a minute ago may belong to a session that is just starting.
        try fixture.installFreshEntry(now: now)

        let report = await fixture.adapter(now: { now }).orphanReport()
        #expect(report.companions.map(\.sessionID) == [Self.orphanID])
        #expect(report.desktopEntries.map(\.url) == [fixture.registryFile(Desktop.orphanEntry)])
        #expect(report.orphanSummary == "1 companion folder and 1 Claude Desktop entry whose transcript is gone.")
        #expect(report.orphanBytes > 2048)
    }

    @Test("orphan plan moves companions, removes the Desktop entry; undo puts both back")
    func orphanPlanRoundTrip() async throws {
        let fixture = try fixture()
        let adapter = fixture.adapter()
        let plan = try await adapter.orphanPlan(.orphans, destination: .quarantine)
        #expect(plan.moves.map(\.source.lastPathComponent) == [Self.orphanID])
        #expect(plan.registryRemovals.map(\.file) == [fixture.registryFile(Desktop.orphanEntry)])
        #expect(plan.mustNotBeRunning == [ClaudeDesktopRegistry.processMatcher])
        #expect(!plan.liveCheck.isLive)

        let executor = fixture.executor()
        let entry = try executor.execute(plan)
        #expect(!fixture.exists("file-history/\(Self.orphanID)"))
        #expect(fixture.exists("file-history/\(Self.freshID)"))
        #expect(!FileManager.default.fileExists(atPath: fixture.registryFile(Desktop.orphanEntry).path))
        #expect(await adapter.orphanReport().orphans.isEmpty)

        _ = try executor.undo(entry)
        #expect(fixture.exists("file-history/\(Self.orphanID)/snapshot@v1"))
        #expect(FileManager.default.fileExists(atPath: fixture.registryFile(Desktop.orphanEntry).path))
    }

    @Test("with Claude Desktop running, the orphan plan is blocked")
    func orphanPlanBlockedByDesktop() async throws {
        let fixture = try fixture()
        let adapter = fixture.adapter(desktopProcesses: FixedProcessLister([RunningProcess(pid: 9, name: "Claude")]))
        let plan = try await adapter.orphanPlan(.orphans, destination: .quarantine)
        #expect(plan.liveCheck.isLive)
        #expect(throws: ExecutorError.self) { try fixture.executor().execute(plan) }
    }

    @Test("duplicates: set-aside copies, earlier Desktop transcripts and double entries; the newest stays")
    func duplicates() async throws {
        let now = Date()
        let fixture = try fixture(now: now)
        let orphaned = "projects/\(Self.project)/\(IDs.idle).orphaned-20261101-x7q2k.jsonl"
        let superseded = "projects/\(Self.project)/\(IDs.idle).jsonl.superseded-20261101-120000"
        // The orphaned copy is newer than the transcript: it stays, and so does the transcript.
        try setDate(fixture, orphaned, now.addingTimeInterval(-3_600))
        try setDate(fixture, superseded, now.addingTimeInterval(-9 * 86_400))
        // Desktop continued the idle conversation from an earlier transcript (#89592).
        let prior = fixture.transcript(Self.priorID, project: Self.project)
        try Data(SecretSamples.claudeLine("Fix the flaky test", session: Self.priorID).utf8).write(to: prior)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-6 * 86_400)], ofItemAtPath: prior.path)
        try fixture.editRegistry(Desktop.idleEntry) { $0["priorCliSessionIds"] = [Self.priorID] }

        let report = await fixture.adapter(now: { now }).orphanReport()
        let items = report.duplicateItems
        #expect(Set(items.map(\.kind)) == [.duplicateCopy, .duplicateSession, .duplicateDesktopEntry])
        #expect(items.filter { $0.kind == .duplicateCopy }.map(\.url.lastPathComponent) == [URL(fileURLWithPath: superseded).lastPathComponent])
        #expect(items.filter { $0.kind == .duplicateSession }.map(\.sessionID) == [Self.priorID])
        #expect(items.filter { $0.kind == .duplicateDesktopEntry }.map(\.url) == [fixture.registryFile(Desktop.expiringOlder)])
        let copies = try #require(report.duplicates.first { $0.extra.contains { $0.kind == .duplicateCopy } })
        #expect(copies.kept.contains(fixture.transcript(IDs.idle, project: Self.project)))
        #expect(copies.kept.map(\.lastPathComponent).contains(URL(fileURLWithPath: orphaned).lastPathComponent))

        let plan = try await fixture.adapter(now: { now }).orphanPlan(.duplicates, destination: .quarantine)
        #expect(Set(plan.moves.map(\.source.lastPathComponent)) == [URL(fileURLWithPath: superseded).lastPathComponent, "\(Self.priorID).jsonl"])
        #expect(plan.registryRemovals.map(\.file) == [fixture.registryFile(Desktop.expiringOlder)])
        let executor = fixture.executor()
        let entry = try executor.execute(plan)
        #expect(fixture.exists("projects/\(Self.project)/\(IDs.idle).jsonl"))
        #expect(fixture.exists(orphaned))
        #expect(!fixture.exists(superseded))
        #expect(!FileManager.default.fileExists(atPath: prior.path))
        #expect(FileManager.default.fileExists(atPath: fixture.registryFile(Desktop.expiringNewer).path))

        _ = try executor.undo(entry)
        #expect(fixture.exists(superseded))
        #expect(FileManager.default.fileExists(atPath: prior.path))
        #expect(FileManager.default.fileExists(atPath: fixture.registryFile(Desktop.expiringOlder).path))
    }

    @Test("a transcript Desktop points at is never a duplicate, even when an earlier copy is newer")
    func pointedAtStays() async throws {
        let now = Date()
        let fixture = try fixture(now: now)
        let prior = fixture.transcript(Self.priorID, project: Self.project)
        try Data(SecretSamples.claudeLine("Fix the flaky test", session: Self.priorID).utf8).write(to: prior)
        try fixture.editRegistry(Desktop.idleEntry) { $0["priorCliSessionIds"] = [Self.priorID] }
        // The prior copy was written just now, after the idle transcript.
        let report = await fixture.adapter(now: { now }).orphanReport()
        #expect(!report.duplicateItems.contains { $0.sessionID == IDs.idle && $0.kind == .duplicateSession })
    }

    @Test("a live session's companions and copies stay out of the plan")
    func liveStays() async throws {
        let fixture = try fixture()
        let copy = "projects/\(Self.project)/\(IDs.live).orphaned-20261101-aaaaa.jsonl"
        try Data("{}\n".utf8).write(to: fixture.claudeDirectory.appendingPathComponent(copy))
        try setDate(fixture, copy, Date().addingTimeInterval(-86_400 * 3))
        let plan = try await fixture.adapter().orphanPlan(.duplicates, destination: .quarantine)
        #expect(!plan.moves.contains { $0.source.lastPathComponent.hasPrefix(IDs.live) })
        #expect(plan.remarks.contains { $0.contains("live") })
    }
}

extension FixtureHome {
    /// A fifth registry entry, written a minute ago, for a transcript that does not exist yet.
    func installFreshEntry(now: Date) throws {
        let url = registryDirectory.appendingPathComponent("\(Desktop.folder)/local_5e1d2f3a-0000-4000-8000-000000000005.json")
        let object: [String: Any] = ["sessionId": "local_5e1d2f3a-0000-4000-8000-000000000005", "cliSessionId": "77777777-7777-4777-8777-777777777777", "isArchived": false, "title": "Just started"]
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: url.path)
    }
}
