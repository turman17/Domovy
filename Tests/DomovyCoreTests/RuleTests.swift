@testable import DomovyCore
import Foundation
import Testing

@Suite("Cleanup rules")
struct RuleTests {
    typealias IDs = FixtureHome.ClaudeCode
    static let day: TimeInterval = 86_400

    private func runner(_ fixture: FixtureHome, minimumIdle: TimeInterval = day) -> RuleRunner {
        let context = DomovyContext(home: fixture.home, isCustomHome: true, adapters: [fixture.adapter()], executor: fixture.executor())
        return RuleRunner(context: context, minimumIdle: minimumIdle)
    }

    /// Quarantine, never the real Trash.
    private func quarantineRule(idleDays: Int = 1) -> CleanupRule {
        CleanupRule(isEnabled: true, action: .moveToQuarantine, condition: RuleCondition(idleDays: idleDays))
    }

    private func session(
        _ id: String = "s1", agent: AgentKind = .codex, project: String? = "/Users/dev/code/orbit-api", ageDays: Double,
        bytes: Int64 = 1_000, status: Session.Status = .idle, expiresInDays: Double? = nil, archived: Bool = false, now: Date
    ) -> Session {
        Session(
            id: id, agent: agent, title: "Synthetic", projectPath: project, lastActive: now.addingTimeInterval(-ageDays * Self.day),
            sizeBytes: bytes, status: status, expiresAt: expiresInDays.map { now.addingTimeInterval($0 * Self.day) },
            transcriptURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"), isArchived: archived
        )
    }

    // MARK: Model

    @Test("presets start off and the store returns them until something is saved")
    func presetsOff() throws {
        let fixture = try FixtureHome()
        let store = RuleStore(storeRoot: fixture.storeRoot)
        let rules = try store.rules()
        #expect(rules.map(\.presetID) == ["archive-before-claude-sweep", "archive-idle-30", "trash-idle-90"])
        #expect(rules.allSatisfy { !$0.isEnabled && !$0.askBeforeRunning && $0.validationProblem == nil })
        #expect(Set(rules.map { $0.id.uuidString.prefix(8) }).count == rules.count, "ids are told apart by their first 8 characters")
        #expect(!FileManager.default.fileExists(atPath: store.rulesFile.path))
    }

    @Test("rules, history and schedule state survive a round trip")
    func persistence() throws {
        let fixture = try FixtureHome()
        let store = RuleStore(storeRoot: fixture.storeRoot)
        var rule = CleanupRule(
            name: "Old Codex", isEnabled: true, askBeforeRunning: true, action: .moveToQuarantine,
            scope: RuleScope(agents: [.codex, .claudeCode], projects: ["orbit"], statuses: [.idle, .archived]),
            condition: RuleCondition(idleDays: 30, minimumBytes: 50_000_000, archivedDays: 10, expiresWithinDays: 3),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000) // whole seconds: dates are stored as ISO 8601
        )
        try store.upsert(rule)
        #expect(try store.rules().count == CleanupRule.presets.count + 1)
        #expect(try store.rules().last == rule)
        rule.isEnabled = false
        try store.upsert(rule)
        #expect(try store.rules().filter { $0.id == rule.id } == [rule])
        try store.remove(rule.id)
        #expect(try store.rules() == CleanupRule.presets)

        let run = RuleRunRecord(startedAt: Date(timeIntervalSince1970: 1_000), finishedAt: Date(timeIntervalSince1970: 1_010), trigger: .scheduled,
                                ruleIDs: [rule.id], outcome: .completed, archivedSessions: 2, bytes: 42, undoGroupID: UUID(), entryIDs: [UUID()],
                                skipped: [RuleSkip(ruleID: rule.id, agent: .codex, sessionID: "x", reason: "Live")])
        try store.record(run)
        #expect(try store.history() == [run])
        try store.save(RuleScheduleState(anchor: Date(timeIntervalSince1970: 5), lastScheduledRun: nil))
        #expect(store.scheduleState().anchor == Date(timeIntervalSince1970: 5))
        let attributes = try FileManager.default.attributesOfItem(atPath: store.historyFile.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test("matching: scope, every condition, live never, archive skips archived")
    func matching() {
        let now = Date()
        let rule = CleanupRule(action: .archive, scope: RuleScope(agents: [.codex], projects: ["ORBIT"]), condition: RuleCondition(idleDays: 30, minimumBytes: 500))
        #expect(rule.matches(session(ageDays: 31, now: now), archivedAt: nil, now: now))
        #expect(!rule.matches(session(ageDays: 29, now: now), archivedAt: nil, now: now))
        #expect(!rule.matches(session(ageDays: 31, bytes: 100, now: now), archivedAt: nil, now: now))
        #expect(!rule.matches(session(agent: .gemini, ageDays: 31, now: now), archivedAt: nil, now: now))
        #expect(!rule.matches(session(project: "/Users/dev/code/landing", ageDays: 31, now: now), archivedAt: nil, now: now))
        #expect(!rule.matches(session(ageDays: 31, status: .live, now: now), archivedAt: nil, now: now))
        #expect(!rule.matches(session(ageDays: 31, status: .archived, archived: true, now: now), archivedAt: nil, now: now))

        let trashArchived = CleanupRule(action: .moveToTrash, condition: RuleCondition(archivedDays: 10))
        let archived = session(ageDays: 40, status: .archived, archived: true, now: now)
        #expect(trashArchived.matches(archived, archivedAt: now.addingTimeInterval(-11 * Self.day), now: now))
        #expect(!trashArchived.matches(archived, archivedAt: now.addingTimeInterval(-2 * Self.day), now: now))
        #expect(trashArchived.matches(archived, archivedAt: nil, now: now), "without a record it counts from the last activity")
        #expect(!trashArchived.matches(session(ageDays: 40, now: now), archivedAt: nil, now: now))

        let sweep = CleanupRule.preset("archive-before-claude-sweep")
        #expect(sweep?.matches(session(agent: .claudeCode, ageDays: 25, expiresInDays: 5, now: now), archivedAt: nil, now: now) == true)
        #expect(sweep?.matches(session(agent: .claudeCode, ageDays: 5, expiresInDays: 25, now: now), archivedAt: nil, now: now) == false)
        #expect(sweep?.matches(session(agent: .claudeCode, ageDays: 5, status: .expiring, now: now), archivedAt: nil, now: now) == true)

        let statusRule = CleanupRule(action: .moveToTrash, scope: RuleScope(statuses: [.expiring]), condition: RuleCondition(idleDays: 1))
        #expect(!statusRule.matches(session(ageDays: 5, now: now), archivedAt: nil, now: now))
        #expect(statusRule.matches(session(ageDays: 5, status: .expiring, now: now), archivedAt: nil, now: now))
        #expect(CleanupRule(action: .archive, condition: RuleCondition()).validationProblem != nil)
        #expect(!CleanupRule(action: .archive, condition: RuleCondition()).matches(session(ageDays: 99, now: now), archivedAt: nil, now: now))
    }

    @Test("sentences read as plain language")
    func sentences() {
        let codex = CleanupRule(action: .archive, scope: RuleScope(agents: [.codex]), condition: RuleCondition(idleDays: 30))
        #expect(codex.sentence == "Archive Codex sessions idle for 30 days")
        let trash = CleanupRule(action: .moveToTrash, scope: RuleScope(projects: ["orbit"]), condition: RuleCondition(idleDays: 90, minimumBytes: 50_000_000))
        #expect(trash.sentence == "Move sessions in \u{201C}orbit\u{201D} idle for 90 days and larger than 50 MB to the Trash")
    }

    @Test("a session two rules match gets one action, removal first; recent sessions are left alone")
    func assignment() {
        let now = Date()
        let archive = CleanupRule(action: .archive, condition: RuleCondition(idleDays: 30))
        let trash = CleanupRule(action: .moveToTrash, condition: RuleCondition(idleDays: 90))
        let tiny = CleanupRule(action: .moveToTrash, condition: RuleCondition(minimumBytes: 1))
        let sessions = [session("old", ageDays: 100, now: now), session("mid", ageDays: 40, now: now)]
        let result = RuleRunner.assign([archive, trash], to: sessions, archivedAt: [:], now: now, minimumIdle: Self.day)
        #expect(result.assigned.map(\.session.id) == ["old", "mid"])
        #expect(result.assigned.map(\.rule.id) == [trash.id, archive.id])
        let recent = RuleRunner.assign([tiny], to: [session("new", ageDays: 0.1, now: now)], archivedAt: [:], now: now, minimumIdle: Self.day)
        #expect(recent.assigned.isEmpty && recent.recentlyActive == 1)
    }

    @Test("the schedule runs once a night at 3, starting the night after it first looked")
    func schedule() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let schedule = RuleSchedule(hour: 3, calendar: calendar)
        let evening = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 22)))
        let night = evening.addingTimeInterval(6 * 3_600) // 04:00 next day
        #expect(!schedule.isDue(now: evening, state: RuleScheduleState()))
        let state = RuleScheduleState(anchor: evening)
        #expect(!schedule.isDue(now: evening.addingTimeInterval(3_600), state: state))
        #expect(schedule.isDue(now: night, state: state))
        #expect(!schedule.isDue(now: night, state: RuleScheduleState(anchor: evening, lastScheduledRun: night.addingTimeInterval(-60))))
        #expect(schedule.nextRun(now: evening, state: state) == evening.addingTimeInterval(5 * 3_600))
        #expect(PowerState(isOnBattery: true, batteryPercent: 15, isLowPowerMode: false).skipReason != nil)
        #expect(PowerState(isOnBattery: true, batteryPercent: 60, isLowPowerMode: false).skipReason == nil)
        #expect(PowerState(isOnBattery: false, batteryPercent: 10, isLowPowerMode: true).skipReason != nil)
        #expect(PowerState.pluggedIn.skipReason == nil)
    }

    // MARK: Runner on a fixture home

    @Test("the dry run is exactly the batch plan, and live sessions are left alone with a reason")
    func dryRunEqualsPlan() async throws {
        let fixture = try FixtureHome()
        let runner = runner(fixture)
        let rule = quarantineRule()
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.claudeDirectory.appendingPathComponent("projects").path)
        let preview = await runner.preview([rule])
        #expect(Set(preview.matches.map(\.session.id)) == [IDs.idle, IDs.expiring])
        // The other live session is an hour old, so the idle condition leaves it out anyway.
        #expect(preview.skipped.compactMap(\.sessionID) == [IDs.rosterLive])
        #expect(preview.skipped.allSatisfy { $0.reason.hasPrefix("Live") })

        let adapter = fixture.adapter()
        let sessions = try await adapter.sessions().filter { [IDs.idle, IDs.expiring].contains($0.id) }
        let direct = await adapter.deletePlans(for: sessions, destination: .quarantine).compactMap(\.plan)
        for plan in direct {
            let match = try #require(preview.matches.first { $0.session.id == plan.sessionID })
            #expect(match.plan.moves == plan.moves)
            #expect(match.plan.indexEdits == plan.indexEdits)
            #expect(match.plan.destination == .quarantine)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.claudeDirectory.appendingPathComponent("projects").path) == before)
        #expect(try fixture.executor().undoLog.entries().isEmpty, "a dry run changes nothing")
    }

    @Test("a run executes as one undo group, records history, and undo puts everything back")
    func runGroupsUndo() async throws {
        let fixture = try FixtureHome()
        let runner = runner(fixture)
        let rule = quarantineRule()
        let preview = await runner.preview([rule])
        let record = await runner.run([rule], trigger: .manual)
        #expect(record.outcome == .completed)
        #expect(record.removedSessions == preview.matches.count && record.removedSessions == 2)
        #expect(record.removedTo == .quarantine)
        #expect(record.bytes == preview.totalBytes)
        let entries = try fixture.executor().undoLog.entries()
        #expect(entries.count == 2)
        #expect(Set(entries.map(\.batchID)) == [record.undoGroupID])
        #expect(Set(entries.map(\.sessionID)) == [IDs.idle, IDs.expiring])
        #expect(Set(entries.map(\.id)) == Set(record.entryIDs))
        #expect(!FileManager.default.fileExists(atPath: fixture.transcript(IDs.idle, project: "-Users-dev-code-orbit-api").path))
        #expect(FileManager.default.fileExists(atPath: fixture.transcript(IDs.live, project: "-Users-dev-code-orbit-api").path))
        #expect(try runner.store.history().first?.id == record.id)
        #expect(record.summary == "Moved 2 sessions to the Domovy quarantine folder (\(ByteCountFormatter.string(fromByteCount: record.bytes, countStyle: .file))).")

        let undone = try runner.undo(record)
        #expect(undone.count == 2)
        #expect(FileManager.default.fileExists(atPath: fixture.transcript(IDs.idle, project: "-Users-dev-code-orbit-api").path))
        #expect(try runner.store.history().first?.undoneAt != nil)
        #expect(runner.pendingEntries(of: record).isEmpty)
    }

    @Test("a run with a reviewed set touches only those sessions")
    func reviewedSetOnly() async throws {
        let fixture = try FixtureHome()
        let runner = runner(fixture)
        let keys: Set<String> = [RuleRunner.key(.claudeCode, IDs.expiring)]
        let record = await runner.run([quarantineRule()], trigger: .manual, only: keys)
        #expect(record.removedSessions == 1)
        #expect(try fixture.executor().undoLog.entries().map(\.sessionID) == [IDs.expiring])
    }

    @Test("sessions active within the minimum idle time are left alone")
    func recentLeftAlone() async throws {
        let fixture = try FixtureHome()
        let preview = await runner(fixture, minimumIdle: 3 * Self.day).preview([CleanupRule(action: .moveToQuarantine, condition: RuleCondition(minimumBytes: 1))])
        #expect(preview.matches.map(\.session.id) == [IDs.expiring])
        #expect(preview.notes.contains { $0.contains("active in the last day") })
    }

    @Test("an archive rule compresses and a scheduled run skips rules that ask first")
    func scheduledSkipsAskRules() async throws {
        let fixture = try FixtureHome()
        // ditto skips files of 16 KiB or less: grow the idle session so it has something to compress.
        try fixture.appendSyntheticLines(to: "projects/-Users-dev-code-orbit-api/\(IDs.idle).jsonl", kilobytes: 400)
        let runner = runner(fixture)
        let archive = CleanupRule(isEnabled: true, action: .archive, condition: RuleCondition(idleDays: 1))
        var asking = quarantineRule()
        asking.askBeforeRunning = true
        try runner.store.save([archive, asking, CleanupRule(isEnabled: false, action: .moveToQuarantine, condition: RuleCondition(idleDays: 1))])
        let (record, review) = try await runner.runScheduled(power: .pluggedIn)
        #expect(record.archivedSessions == 1 && record.removedSessions == 0)
        let entries = try fixture.executor().undoLog.entries()
        #expect(entries.map(\.action) == [.archive] && entries.map(\.sessionID) == [IDs.idle])
        let pending = try #require(review)
        #expect(Set(pending.matches.map(\.session.id)) == [IDs.idle, IDs.expiring], "removal rules also take archived sessions")
        #expect(pending.matches.allSatisfy { $0.rule.id == asking.id })
        #expect(runner.store.scheduleState().lastScheduledRun != nil)
        #expect(runner.archiveDates()[RuleRunner.key(.claudeCode, IDs.idle)] != nil)
    }

    @Test("a scheduled run on low battery changes nothing")
    func lowBattery() async throws {
        let fixture = try FixtureHome()
        let runner = runner(fixture)
        try runner.store.save([quarantineRule()])
        let (record, review) = try await runner.runScheduled(power: PowerState(isOnBattery: true, batteryPercent: 12, isLowPowerMode: false))
        #expect(record.outcome == .skippedPower && review == nil)
        #expect(try fixture.executor().undoLog.entries().isEmpty)
    }

    @Test("read-only agents are skipped with a note and never planned")
    func readOnlySkipped() async throws {
        let home = try ReadOnlyAgentTests.Home()
        try home.database(".local/share/goose/sessions/sessions.db", fixture: "goose/sql/sessions.sql")
        let adapter = GooseAdapter(home: home.home, openHandles: ReadOnlyAgentTests.quiet)
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("domovy-rules-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: store) }
        let context = DomovyContext(home: home.home, isCustomHome: true, adapters: [adapter], executor: Executor(storeRoot: store, processes: FixedProcessLister([])))
        let far = Date().addingTimeInterval(3_650 * Self.day)
        let runner = RuleRunner(context: context, now: { far })
        let before = home.snapshot()
        let record = await runner.run([CleanupRule(action: .moveToQuarantine, condition: RuleCondition(idleDays: 1))], trigger: .manual)
        #expect(record.outcome == .nothingToDo && record.entryIDs.isEmpty)
        let note = try #require(record.skipped.first)
        #expect(note.agent == .goose && note.sessionID == nil && note.reason.contains("only reads"))
        #expect(home.snapshot() == before)
    }

    // MARK: MCP

    @Test("MCP offers list_rules and plan_rules read-only, and nothing that runs a rule")
    func mcpTools() async throws {
        let fixture = try FixtureHome()
        let context = DomovyContext(home: fixture.home, isCustomHome: true, adapters: [fixture.adapter()], executor: fixture.executor())
        try RuleStore(storeRoot: context.executor.storeRoot).save([quarantineRule()])
        let tools = DomovyTools(context: context)
        let names = DomovyTools.definitions.map(\.name)
        #expect(names.contains("list_rules") && names.contains("plan_rules"))
        #expect(!names.contains { $0.contains("rule") && !$0.hasPrefix("list") && !$0.hasPrefix("plan") })
        let listed = await tools.call("list_rules", arguments: [:])
        #expect(!listed.isError && listed.structured["rules"]?.arrayValue?.count == 1)
        let planned = await tools.call("plan_rules", arguments: [:])
        #expect(!planned.isError)
        #expect(planned.structured["match_count"] == .int(2))
        #expect(try fixture.executor().undoLog.entries().isEmpty)
    }
}
