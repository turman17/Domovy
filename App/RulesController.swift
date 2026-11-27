import AppKit
import DomovyCore
import Foundation
import Observation
import os

/// Rules, their history and the nightly run. The menu bar app keeps running, so the scheduler
/// lives here rather than in a window: it checks every few minutes and on wake, and runs the
/// rules that are on once a night at the hour set in Settings, 3:00 by default (or at the first
/// check after, if the Mac slept).
@MainActor
@Observable
final class RulesController {
    private(set) var rules: [CleanupRule] = []
    private(set) var history: [RuleRunRecord] = []
    private(set) var isRunning = false
    private(set) var scheduleState = RuleScheduleState()
    /// When Domovy archived each session, for "archived for N days" and the estimate.
    private(set) var archiveDates: [String: Date] = [:]
    /// Runs whose changes are still in the undo log, waiting.
    private(set) var undoableRuns: Set<UUID> = []
    /// What a scheduled run left for the user ("ask before running"); Settings > Cleanup Rules offers it.
    var pendingReview: RulePreview?
    /// The review or preview sheet on Settings > Cleanup Rules.
    var reviewRequest: RuleReviewRequest?
    var errorMessage: String?
    /// Set by a notification so Settings opens on Cleanup Rules.
    var wantsSettings = false

    private(set) var schedule = RuleSchedule(hour: AppSettings.shared.settings.nightlyHour)
    let notifications = RulesNotifications()
    private let home: URL
    private let isCustomHome: Bool
    private(set) weak var library: SessionLibrary?
    private var runner: RuleRunner?
    private var store: RuleStore
    private var ticker: Task<Void, Never>?
    /// Undo actions on the window's stack, by run, so Undo from history takes the same one off.
    private var undoActions: [UUID: UndoAction] = [:]
    private let logger = Logger(subsystem: "io.github.turman17.Domovy", category: "Rules")

    init(home: URL, storeRoot: URL, isCustomHome: Bool) {
        self.home = home
        self.isCustomHome = isCustomHome
        store = RuleStore(storeRoot: storeRoot)
        load()
        notifications.controller = self
    }

    /// Connects the session library (its adapters, executor, undo stack) and starts the
    /// scheduler. Called by the window and the popover; later calls do nothing.
    func attach(_ library: SessionLibrary) {
        guard self.library == nil else { return }
        self.library = library
        makeRunner()
        library.onAdaptersChanged = { [weak self] in self?.makeRunner() }
        notifications.install()
        load()
        startScheduler()
    }

    /// A runner over the library's adapters as they are now (hidden agents left out).
    private func makeRunner() {
        guard let library else { return }
        let context = DomovyContext(home: home, isCustomHome: isCustomHome, adapters: library.adapters, executor: library.executor,
                                    settings: AppSettings.shared.settings)
        runner = RuleRunner(context: context, store: store)
    }

    /// Settings > Cleanup Rules: the hour of the nightly run.
    func apply(_ settings: DomovySettings) {
        guard schedule.hour != settings.nightlyHour else { return }
        let wasDue = schedule.isDue(now: Date(), state: scheduleState)
        schedule.hour = settings.nightlyHour
        // A new hour counts from now: moving it never runs the rules at once.
        if !wasDue, schedule.isDue(now: Date(), state: scheduleState) {
            scheduleState.lastScheduledRun = Date()
            try? store.save(scheduleState)
        }
    }

    /// "3:00", the time of the nightly run in the user's format.
    var scheduledTimeText: String {
        let date = Calendar.current.date(bySettingHour: schedule.hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: State

    var enabledRules: [CleanupRule] { rules.filter(\.isEnabled) }
    var hasEnabledRules: Bool { rules.contains(where: \.isEnabled) }

    /// The next scheduled run, or `nil` while no rule is on.
    var nextRun: Date? {
        guard hasEnabledRules else { return nil }
        return schedule.nextRun(now: Date(), state: scheduleState)
    }

    /// Sessions the rules that are on would take at the next run, from the sessions listed
    /// now (no plans): the menu bar's "12 sessions".
    var upcoming: (count: Int, bytes: Int64) {
        guard let library, hasEnabledRules else { return (0, 0) }
        let result = RuleRunner.assign(enabledRules, to: library.sessions, archivedAt: archiveDates, now: Date(), minimumIdle: 86_400)
        return (result.assigned.count, result.assigned.reduce(0) { $0 + $1.session.sizeBytes })
    }

    func lastRun(of rule: CleanupRule) -> RuleRunRecord? {
        history.first { $0.ruleIDs.contains(rule.id) && $0.outcome != .skippedPower }
    }

    /// The run can still be undone: it changed something and its entries are pending.
    func canUndo(_ record: RuleRunRecord) -> Bool {
        undoableRuns.contains(record.id)
    }

    /// Reads rules, history and the undo log again (after ⌘Z, `domo rules` or `domo undo`).
    func refresh() { load() }

    private func load() {
        do {
            rules = try store.rules()
            history = try store.history()
        } catch {
            errorMessage = error.localizedDescription
        }
        scheduleState = store.scheduleState()
        guard let runner else { return }
        archiveDates = runner.archiveDates()
        // Read the undo log once here, not once per history row on every redraw.
        let pending = Set(((try? runner.context.executor.undoLog.entries()) ?? []).filter(\.isUndoable).map(\.id))
        undoableRuns = Set(history.filter { $0.undoneAt == nil && !pending.isDisjoint(with: $0.entryIDs) }.map(\.id))
    }

    // MARK: Editing

    func save(_ rule: CleanupRule) {
        let wasOff = !hasEnabledRules
        do {
            try store.upsert(rule)
            load()
            if wasOff, rule.isEnabled { firstRuleEnabled() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setEnabled(_ rule: CleanupRule, _ on: Bool) {
        var changed = rule
        changed.isEnabled = on
        save(changed)
    }

    func remove(_ rule: CleanupRule) {
        do {
            try store.remove(rule.id)
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The first rule turned on: ask to notify, and start counting nights from now.
    private func firstRuleEnabled() {
        notifications.requestAuthorization()
        if scheduleState.anchor == nil {
            scheduleState.anchor = Date()
            try? store.save(scheduleState)
        }
    }

    // MARK: Preview and run

    func preview(_ rules: [CleanupRule]) async -> RulePreview? {
        guard let runner else { return nil }
        return await Task.detached { await runner.preview(rules) }.value
    }

    /// Runs exactly the sessions a preview showed, planned again with fresh live checks.
    func run(_ rules: [CleanupRule], reviewed preview: RulePreview) async {
        guard let runner, !isRunning else { return }
        isRunning = true
        let keys = preview.sessionKeys
        // Off the main actor: the executor moves and compresses files synchronously.
        let record = await Task.detached { await runner.run(rules, trigger: .manual, only: keys) }.value
        isRunning = false
        if rules.allSatisfy(\.askBeforeRunning) { pendingReview = nil }
        await finish(record, notify: false)
    }

    private func startScheduler() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkSchedule()
                try? await Task.sleep(for: .seconds(600))
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                // Give the disks and the agents a moment after wake.
                try? await Task.sleep(for: .seconds(60))
                await self?.checkSchedule()
            }
        }
    }

    /// Runs the nightly rules when one is due. Waits while another action runs in the window.
    func checkSchedule() async {
        guard let runner, let library, hasEnabledRules, !isRunning else { return }
        if scheduleState.anchor == nil {
            scheduleState.anchor = Date()
            try? store.save(scheduleState)
            return
        }
        guard schedule.isDue(now: Date(), state: scheduleState), library.backgroundActivity == nil else { return }
        isRunning = true
        do {
            let (record, review) = try await Task.detached { try await runner.runScheduled(power: PowerState.current()) }.value
            isRunning = false
            await finish(record, notify: true)
            if let review {
                pendingReview = review
                notifications.postReview(review)
            }
        } catch {
            isRunning = false
            logger.error("Scheduled rules run failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    private func finish(_ record: RuleRunRecord, notify: Bool) async {
        load()
        guard let library, let runner, record.changedAnything else { return }
        let action = UndoAction(name: "Rules Run", entries: runner.pendingEntries(of: record))
        undoActions[record.id] = action
        library.register(action)
        await library.reload()
        if notify {
            notifications.postRun(record)
        } else {
            library.toast = Toast(message: record.summary, undo: action)
        }
    }

    /// Undoes a run from the history or the notification.
    func undo(_ record: RuleRunRecord) async {
        guard let library, let runner else { return }
        let action = undoActions[record.id] ?? UndoAction(name: "Rules Run", entries: runner.pendingEntries(of: record))
        do {
            try await library.undo(action)
            var updated = record
            updated.undoneAt = Date()
            try store.record(updated)
            undoActions[record.id] = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        load()
    }

    func undo(recordID: UUID) async {
        guard let record = history.first(where: { $0.id == recordID }) else { return }
        await undo(record)
    }

    /// The notification's Review: opens Settings on Cleanup Rules with the plan, planned again now.
    func review() async {
        let asking = enabledRules.filter(\.askBeforeRunning)
        guard !asking.isEmpty, let preview = await preview(asking) else { return }
        pendingReview = preview.isEmpty ? nil : preview
        reviewRequest = RuleReviewRequest(rules: asking, preview: preview)
        wantsSettings = true
    }

    /// "tonight at 3:00", "tomorrow at 3:00", "now".
    static func describe(_ date: Date, now: Date = Date()) -> String {
        if date.timeIntervalSince(now) < 60 { return "now" }
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        if calendar.isDateInTomorrow(date), hour < 6, calendar.component(.hour, from: now) >= 12 { return "tonight at \(time)" }
        if calendar.isDateInToday(date) { return hour < 6 ? "tonight at \(time)" : "today at \(time)" }
        if calendar.isDateInTomorrow(date) { return "tomorrow at \(time)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Rules and the plan a review sheet shows.
struct RuleReviewRequest: Identifiable {
    let id = UUID()
    let rules: [CleanupRule]
    /// Planned already (a scheduled run that asks first), or `nil` to plan when the sheet opens.
    var preview: RulePreview?
    /// The sheet only shows what would happen; no Run button (the editor's Preview).
    var isPreviewOnly = false
}
