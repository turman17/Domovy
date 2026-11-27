import Foundation
import os

/// One session a rule acts on, with the plan that does it.
public struct RuleMatch: Identifiable, Sendable {
    public let rule: CleanupRule
    public let session: Session
    public let plan: Plan

    public var id: UUID { plan.id }
}

/// What the rules would do right now: the plans, and every session left alone with the reason.
/// The same value backs the Rules preview, the review sheet, `domo rules run --dry-run` and
/// `plan_rules`; a run executes exactly these plans, computed again right before.
public struct RulePreview: Sendable {
    public let createdAt: Date
    public let matches: [RuleMatch]
    public let skipped: [RuleSkip]
    /// Counts the user should know ("2 sessions active in the last day are left alone.").
    public let notes: [String]

    public init(createdAt: Date, matches: [RuleMatch], skipped: [RuleSkip], notes: [String]) {
        self.createdAt = createdAt
        self.matches = matches
        self.skipped = skipped
        self.notes = notes
    }

    public var isEmpty: Bool { matches.isEmpty }
    public var totalBytes: Int64 { matches.reduce(0) { $0 + $1.plan.totalBytes } }
    public var archiveMatches: [RuleMatch] { matches.filter { $0.plan.action == .archive } }
    public var removeMatches: [RuleMatch] { matches.filter { $0.plan.action == .delete } }

    public func matches(for rule: UUID) -> [RuleMatch] { matches.filter { $0.rule.id == rule } }

    /// Agent and id of every matched session, to run exactly what a review showed.
    public var sessionKeys: Set<String> { Set(matches.map { RuleRunner.key($0.session) }) }

    /// "Archives 12 sessions (340 MB) and moves 3 sessions (1.2 GB) to the Trash. You can undo this."
    public var summary: String {
        guard !matches.isEmpty else { return "Nothing matches right now." }
        func bytes(_ items: [RuleMatch]) -> String {
            ByteCountFormatter.string(fromByteCount: items.reduce(0) { $0 + $1.plan.totalBytes }, countStyle: .file)
        }
        var parts: [String] = []
        let archive = archiveMatches
        if !archive.isEmpty { parts.append("archives \(RuleRunRecord.sessions(archive.count)) (\(bytes(archive)))") }
        for destination in [Destination.trash, .quarantine] {
            let items = removeMatches.filter { $0.plan.destination == destination }
            if !items.isEmpty { parts.append("moves \(RuleRunRecord.sessions(items.count)) (\(bytes(items))) to \(destination.displayName)") }
        }
        let text = parts.joined(separator: " and ")
        return text.prefix(1).uppercased() + text.dropFirst() + ". You can undo this."
    }
}

/// Plans and runs the cleanup rules with the adapters' batch APIs and the executor. Live
/// sessions, sessions active in the last day and read-only agents are always left alone;
/// a session two rules match gets one action, removal over archive.
public struct RuleRunner: Sendable {
    public let context: DomovyContext
    public let store: RuleStore
    /// Sessions written to more recently than this are never touched by a rule.
    public let minimumIdle: TimeInterval
    let now: @Sendable () -> Date

    public init(context: DomovyContext, store: RuleStore? = nil, minimumIdle: TimeInterval = 86_400, now: @escaping @Sendable () -> Date = { Date() }) {
        self.context = context
        self.store = store ?? RuleStore(storeRoot: context.executor.storeRoot)
        self.minimumIdle = minimumIdle
        self.now = now
    }

    static func key(_ session: Session) -> String { "\(session.agent.rawValue)/\(session.id)" }
    static func key(_ agent: AgentKind, _ id: String) -> String { "\(agent.rawValue)/\(id)" }

    // MARK: Matching

    /// Which rule takes each session, in session order: the first removal rule that matches,
    /// else the first archive rule. Pure, so the menu bar can estimate from listed sessions.
    /// - Returns: the assignments and how many matching sessions were too recently active.
    public static func assign(
        _ rules: [CleanupRule], to sessions: [Session], archivedAt: [String: Date], now: Date, minimumIdle: TimeInterval
    ) -> (assigned: [(rule: CleanupRule, session: Session)], recentlyActive: Int) {
        let usable = rules.filter { $0.validationProblem == nil }
        var assigned: [(rule: CleanupRule, session: Session)] = []
        var recent = 0
        for session in sessions {
            let date = archivedAt[key(session)]
            let matching = usable.filter { $0.matches(session, archivedAt: date, now: now) }
            guard let rule = matching.first(where: { $0.action != .archive }) ?? matching.first else { continue }
            if now.timeIntervalSince(session.lastActive) < minimumIdle {
                recent += 1
                continue
            }
            assigned.append((rule, session))
        }
        return (assigned, recent)
    }

    /// When Domovy archived each session it still holds archived, by `key`.
    public func archiveDates() -> [String: Date] {
        let entries = (try? context.executor.undoLog.entries()) ?? []
        var dates: [String: Date] = [:]
        for entry in entries where entry.action == .archive && !entry.isUndone {
            dates[Self.key(entry.agent, entry.sessionID)] = entry.createdAt
        }
        return dates
    }

    // MARK: Preview

    /// The plans `rules` would execute now. Disabled rules count too: the caller picks.
    /// - Parameter keys: only these sessions (a review the user saw), else every match.
    public func preview(_ rules: [CleanupRule], only keys: Set<String>? = nil) async -> RulePreview {
        let date = now()
        let usable = rules.filter { $0.validationProblem == nil }
        guard !usable.isEmpty else { return RulePreview(createdAt: date, matches: [], skipped: [], notes: []) }
        let archived = archiveDates()
        var matches: [RuleMatch] = []
        var skipped: [RuleSkip] = []
        var recent = 0

        for adapter in context.adapters {
            let kind = adapter.kind
            let relevant = usable.filter { $0.scope.agents.isEmpty || $0.scope.agents.contains(kind) }
            guard !relevant.isEmpty else { continue }
            let status = await adapter.status()
            if status == .notInstalled { continue }
            let sessions: [Session]
            do {
                sessions = try await adapter.sessions()
            } catch {
                skipped.append(RuleSkip(ruleID: nil, agent: kind, sessionID: nil, reason: "Could not list \(kind.displayName) sessions: \(error.localizedDescription)"))
                continue
            }
            for session in sessions where session.status == .live {
                if let rule = relevant.first(where: { $0.matchesIgnoringLive(session, archivedAt: archived[Self.key(session)], now: date) }),
                   keys?.contains(Self.key(session)) ?? true {
                    skipped.append(RuleSkip(ruleID: rule.id, agent: kind, sessionID: session.id, reason: "Live: an agent is using it, so Domovy leaves it alone."))
                }
            }
            var (assigned, tooRecent) = Self.assign(relevant, to: sessions, archivedAt: archived, now: date, minimumIdle: minimumIdle)
            if let keys { assigned = assigned.filter { keys.contains(Self.key($0.session)) } } else { recent += tooRecent }
            guard !assigned.isEmpty else { continue }
            if case .readOnly(let reason) = status {
                let n = assigned.count
                skipped.append(RuleSkip(ruleID: nil, agent: kind, sessionID: nil,
                                        reason: "\(RuleRunRecord.sessions(n)) of \(kind.displayName) \(n == 1 ? "matches" : "match"), but Domovy only reads \(kind.displayName): \(reason)"))
                continue
            }
            let ruleBySession = Dictionary(assigned.map { ($0.session.id, $0.rule) }, uniquingKeysWith: { first, _ in first })
            for action in RuleAction.allCases {
                let group = assigned.filter { $0.rule.action == action }.map(\.session)
                guard !group.isEmpty else { continue }
                let planned = if let destination = action.destination {
                    await adapter.deletePlans(for: group, destination: destination)
                } else {
                    await adapter.archivePlans(for: group)
                }
                for item in planned {
                    guard let rule = ruleBySession[item.session.id] else { continue }
                    let skip = { (reason: String) in
                        skipped.append(RuleSkip(ruleID: rule.id, agent: kind, sessionID: item.session.id, reason: reason))
                    }
                    switch item.result {
                    case .failure(let error):
                        skip(error.localizedDescription)
                    case .success(let plan):
                        let blocking = plan.mustNotBeRunning.isEmpty ? [] : context.executor.processes.blockingReasons(plan.mustNotBeRunning)
                        if plan.liveCheck.isLive {
                            skip("Live: " + (plan.liveCheck.reasons.first ?? "an agent is using it."))
                        } else if plan.isEmpty {
                            continue
                        } else if let text = plan.acknowledgement {
                            skip("Needs your explicit OK, so rules never run it: \(text)")
                        } else if !blocking.isEmpty {
                            skip("Waits until the app is quit: " + blocking.joined(separator: " "))
                        } else {
                            matches.append(RuleMatch(rule: rule, session: item.session, plan: plan))
                        }
                    }
                }
            }
        }
        var notes: [String] = []
        if recent > 0 {
            notes.append("\(RuleRunRecord.sessions(recent)) active in the last day \(recent == 1 ? "is" : "are") left alone.")
        }
        return RulePreview(createdAt: date, matches: matches, skipped: skipped, notes: notes)
    }

    // MARK: Run

    /// Plans `rules` again and executes them as one undo group, plan by plan: a plan that
    /// fails is skipped with its reason and the others still run. Records the run.
    @discardableResult
    public func run(_ rules: [CleanupRule], trigger: RuleRunRecord.Trigger, only keys: Set<String>? = nil) async -> RuleRunRecord {
        let started = now()
        let preview = await preview(rules, only: keys)
        var record = RuleRunRecord(startedAt: started, finishedAt: started, trigger: trigger, ruleIDs: rules.map(\.id), outcome: .nothingToDo,
                                   skipped: preview.skipped, notes: preview.notes)
        let group = UUID()
        var failures = 0
        for match in preview.matches {
            do {
                let entry = try context.executor.execute(match.plan, batchID: group)
                record.entryIDs.append(entry.id)
                record.bytes += match.plan.totalBytes
                if match.plan.action == .archive {
                    record.archivedSessions += 1
                } else {
                    record.removedTo = record.removedSessions == 0 || record.removedTo == match.plan.destination ? match.plan.destination : nil
                    record.removedSessions += 1
                }
            } catch {
                failures += 1
                record.skipped.append(RuleSkip(ruleID: match.rule.id, agent: match.session.agent, sessionID: match.session.id, reason: error.localizedDescription))
                // A plan that stopped half way left an undoable entry; it belongs to this run.
                if let partial = (try? context.executor.undoLog.entries())?.first(where: { $0.planID == match.plan.id && $0.hasChangesToUndo }) {
                    record.entryIDs.append(partial.id)
                }
            }
        }
        if !record.entryIDs.isEmpty { record.undoGroupID = group }
        record.outcome = preview.matches.isEmpty ? .nothingToDo
            : record.entryIDs.isEmpty ? .failed
            : failures > 0 ? .partial : .completed
        if record.outcome == .failed { record.notes.insert("Nothing changed: every planned session was refused when it ran.", at: 0) }
        record.skipped = Array(record.skipped.prefix(200))
        record.finishedAt = now()
        Log.rules.info("Rules run \(record.id, privacy: .public): \(record.archivedSessions) archived, \(record.removedSessions) removed, \(record.skipped.count) skipped")
        try? store.record(record)
        return record
    }

    /// The nightly run: the enabled rules that need no review execute; the ones that ask first
    /// are only planned, and their preview is returned for a review. Skipped on low battery.
    public func runScheduled(power: PowerState = .current()) async throws -> (record: RuleRunRecord, review: RulePreview?) {
        let rules = try store.rules().filter(\.isEnabled)
        var state = store.scheduleState()
        state.lastScheduledRun = now()
        try store.save(state)
        if let reason = power.skipReason {
            let date = now()
            let record = RuleRunRecord(startedAt: date, finishedAt: date, trigger: .scheduled, ruleIDs: rules.map(\.id), outcome: .skippedPower, notes: [reason])
            try? store.record(record)
            return (record, nil)
        }
        let unattended = rules.filter { !$0.askBeforeRunning }
        let asking = rules.filter(\.askBeforeRunning)
        var record = unattended.isEmpty
            ? RuleRunRecord(startedAt: now(), finishedAt: now(), trigger: .scheduled, ruleIDs: [], outcome: .nothingToDo)
            : await run(unattended, trigger: .scheduled)
        guard !asking.isEmpty else { return (record, nil) }
        let review = await preview(asking)
        if !review.isEmpty {
            let note = "\(RuleRunRecord.sessions(review.matches.count)) \(review.matches.count == 1 ? "waits" : "wait") for your review."
            if record.changedAnything {
                record.notes.append(note)
            } else {
                record.outcome = .awaitingReview
                record.notes.insert(note, at: 0)
            }
            try? store.record(record)
        }
        return (record, review.isEmpty ? nil : review)
    }

    // MARK: Undo

    /// Undoes every change of a run, newest first, and marks it undone in the history.
    @discardableResult
    public func undo(_ record: RuleRunRecord) throws -> [UndoEntry] {
        let ids = Set(record.entryIDs)
        let entries = try context.executor.undoLog.entries().filter { ids.contains($0.id) && $0.isUndoable }
        let undone = try entries.reversed().compactMap { entry -> UndoEntry? in
            do { return try context.executor.undo(entry) } catch ExecutorError.alreadyUndone { return nil }
        }
        var updated = record
        updated.undoneAt = now()
        try store.record(updated)
        return undone
    }

    /// The run's entries still waiting in the undo log, oldest first.
    public func pendingEntries(of record: RuleRunRecord) -> [UndoEntry] {
        let ids = Set(record.entryIDs)
        return ((try? context.executor.undoLog.entries()) ?? []).filter { ids.contains($0.id) && $0.isUndoable }
    }
}

extension CleanupRule {
    /// `matches` without the live check, to say which live sessions a rule left alone.
    func matchesIgnoringLive(_ session: Session, archivedAt: Date?, now: Date) -> Bool {
        guard session.status == .live else { return matches(session, archivedAt: archivedAt, now: now) }
        let idle = Session(
            id: session.id, agent: session.agent, title: nil, projectPath: session.projectPath, lastActive: session.lastActive,
            sizeBytes: session.sizeBytes, status: .idle, expiresAt: session.expiresAt, transcriptURL: session.transcriptURL,
            isArchived: session.isArchived
        )
        return matches(idle, archivedAt: archivedAt, now: now)
    }
}

extension Log {
    /// Counts and ids only; never titles or paths.
    static let rules = Logger(subsystem: subsystem, category: "rules")
}
