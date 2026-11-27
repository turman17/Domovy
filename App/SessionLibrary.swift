import DomovyCore
import Foundation
import Observation
import os

/// Status filter shared by the toolbar, the retention banner and the menu bar popover.
enum StatusFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case idle = "Idle"
    case live = "Live"
    case expiring = "Expiring"
    case archived = "Archived"

    var id: Self { self }

    func matches(_ session: Session) -> Bool {
        switch self {
        case .all: true
        case .idle: session.status == .idle
        case .live: session.status == .live
        case .expiring: session.status == .expiring
        case .archived: session.status == .archived
        }
    }
}

/// The numbers the menu bar item can show next to its icon.
struct MenuBarFigures: Equatable {
    var totalBytes: Int64 = 0
    var safeBytes: Int64 = 0
    var liveSessions = 0
}

/// One Domovy action on the window's undo stack ("Undo Move to Trash", "Undo Archive").
/// Also the UndoManager target, so the toast's Undo button can take it off the stack.
final class UndoAction: Sendable {
    let name: String
    /// Newest last, as executed.
    let entries: [UndoEntry]

    init(name: String, entries: [UndoEntry]) {
        self.name = name
        self.entries = entries
    }
}

/// A short confirmation after an action, with the action it can revert.
struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let undo: UndoAction?

    static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
}

/// Sessions and footprints from every adapter, loaded off the main actor and published for
/// the UI. Also the one place that executes and undoes plans.
@MainActor
@Observable
final class SessionLibrary {
    private(set) var sessions: [Session] = []
    /// Herdr's workspaces, panes and agents at the last reload; empty when Herdr is not running.
    var herdr: HerdrState = .empty
    /// Last measured footprints, kept while a rescan runs so the Disk screen never goes blank.
    private(set) var footprints: [Footprint] = [] {
        didSet { updateMenuBarFigures() }
    }
    /// What the menu bar item may show, replaced only when a number changes, so the item does
    /// not redraw on every reload.
    private(set) var menuBarFigures = MenuBarFigures()
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastScan: Date?
    /// Each agent's own retention sweep, for the banner and the menu bar.
    private(set) var retentionRules: [AgentKind: RetentionRule] = [:]
    /// Agents Domovy only reads, with the reason (Antigravity for now).
    private(set) var readOnlyAgents: [AgentKind: String] = [:]
    var toast: Toast?
    /// Failure of an action started from the menu (⌘Z) or running in the background, shown
    /// by the sessions view.
    var actionError: String?
    /// Sessions an archive or delete is working on in the background, with what is happening
    /// ("Archiving…"). They are not offered for another action until it finishes.
    private(set) var busySessions: [Session.ID: String] = [:]
    /// The background action running now, for the toolbar ("Archiving 3 sessions…").
    private(set) var backgroundActivity: String?
    private var backgroundJob: Task<Void, Never>?
    /// The main window's undo manager. Domovy actions go on the same stack as text edits, so
    /// ⌘Z in the search field undoes typing and ⌘Z elsewhere undoes the last Domovy action.
    weak var undoManager: UndoManager?
    /// Set by the menu bar popover so the main window opens on that filter.
    var requestedFilter: StatusFilter?
    /// Set by the menu bar popover so the main window opens on that section.
    var requestedSection: SidebarItem?
    /// Set by a row's "Show Sessions in This Project" so the toolbar search shows that project.
    var requestedSearch: String?
    /// Set by the menu bar popover so the Disk screen scrolls to a section ("local-models").
    var requestedDiskAnchor: String? = AppEnvironment.startDiskAnchor

    // Secret scan state, changed only by SessionLibrary+Secrets. In memory only: findings are
    // never written to disk (they hold masked previews, never values, either way).
    /// Findings of the last scan, by session id.
    var secretFindings: [Session.ID: [SecretFinding]] = [:]
    var secretScan: SecretScanState = .idle
    var secretScanTask: Task<Void, Never>?
    /// Actions on the undo stack, so a purge can take the ones it ended off it.
    var registeredUndoActions: [UndoAction] = []
    /// Orphans and duplicates of Claude Code and Claude Desktop, for the Disk screen.
    var orphanReport: OrphanReport = .empty
    /// Copies Domovy kept before `ollama rm` and friends deleted the originals, until purged.
    var keptCopyBytes: Int64 = 0

    /// Claude Code with Claude Desktop's list, for the orphan report; listed only when shown.
    let claudeCode: ClaudeCodeAdapter
    let codex: CodexAdapter
    /// Every adapter, in sidebar order, without the agents hidden in Settings. Agents not
    /// installed at this home are skipped on scan.
    private(set) var adapters: [any AgentAdapter]
    /// Every agent the Disk screen measures: the adapters plus Claude Desktop.
    private(set) var footprintProviders: [any FootprintProvider]
    /// The settings the adapters were built with.
    private var adapterSettings: AdapterSettings
    /// Called after the adapters were rebuilt (the rules runner keeps its own copy).
    @ObservationIgnored var onAdaptersChanged: (() -> Void)?
    private let isCustomHome: Bool
    private let models: ModelStores
    let executor: Executor
    /// The Disk screen's guided cleanups.
    let cleanupPlanner: CleanupPlanner
    let home: URL
    /// Full-text search inside transcripts, with its local index.
    let transcriptSearch: TranscriptSearch
    /// Token usage read from transcripts, cached in Domovy's folder (SessionLibrary+Tokens).
    let tokenStore: TokenUsageStore
    var tokenUsage: [Session.ID: TokenUsageResult] = [:]
    /// Bumped when `tokenUsage` changes, so rows rebuild without comparing every entry.
    var tokenRevision = 0
    var tokenTask: Task<Void, Never>?
    let logger = Logger(subsystem: "io.github.turman17.Domovy", category: "SessionLibrary")

    init(home: URL, storeRoot: URL, isCustomHome: Bool) {
        self.home = home
        transcriptSearch = TranscriptSearch(storeRoot: storeRoot)
        tokenStore = TokenUsageStore(storeRoot: storeRoot)
        self.isCustomHome = isCustomHome
        let settings = AppSettings.shared.settings
        claudeCode = ClaudeCodeAdapter(home: home, expiringWindowDays: settings.expiringWindowDays)
        codex = CodexAdapter(home: home, cli: CodexCLI.choice(home: home, isCustomHome: isCustomHome))
        adapterSettings = AdapterSettings(settings)
        let adapters = DomovyContext.standardAdapters(home: home, isCustomHome: isCustomHome, settings: settings)
        self.adapters = adapters
        let models = ModelStores.at(home: home, isCustomHome: isCustomHome)
        self.models = models
        footprintProviders = DomovyContext.footprintProviders(adapters: adapters, home: home, models: models, settings: settings)
        executor = Executor(storeRoot: storeRoot)
        // A custom home (.devhome) runs only the stubs in <home>/bin, never the real ollama or hf.
        cleanupPlanner = CleanupPlanner(
            claudeCodeRoot: claudeCode.root, codexRoot: codex.root,
            desktopSupport: home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true),
            models: models,
            ollamaCLI: ToolChoice.at(home: home, isCustomHome: isCustomHome, name: "ollama", override: "DOMOVY_OLLAMA_CLI"),
            huggingFaceCLI: ToolChoice.at(home: home, isCustomHome: isCustomHome, name: "hf", override: "DOMOVY_HF_CLI"),
            launchdEnvironment: LaunchdEnvironment.reader(isCustomHome: isCustomHome)
        )
        transcriptSearch.isAllowed = settings.transcriptIndex
    }

    /// The parts of the settings the adapters are built from.
    private struct AdapterSettings: Equatable {
        let hidden: Set<AgentKind>
        let expiringWindowDays: Int
        let aiderSearchFolders: [String]

        init(_ settings: DomovySettings) {
            hidden = settings.hiddenAgents
            expiringWindowDays = settings.expiringWindowDays
            aiderSearchFolders = settings.aiderSearchFolders
        }
    }

    /// Rebuilds the adapters and rescans when hidden agents, the expiring window or Aider's
    /// folders changed; does nothing otherwise, so callers may call it on every change.
    func apply(_ settings: DomovySettings) {
        transcriptSearch.isAllowed = settings.transcriptIndex
        let next = AdapterSettings(settings)
        guard next != adapterSettings else { return }
        adapterSettings = next
        adapters = DomovyContext.standardAdapters(home: home, isCustomHome: isCustomHome, settings: settings)
        footprintProviders = DomovyContext.footprintProviders(adapters: adapters, home: home, models: models, settings: settings)
        onAdaptersChanged?()
        Task { await reload() }
    }

    func adapter(for agent: AgentKind) throws -> any AgentAdapter {
        guard let adapter = adapters.first(where: { $0.kind == agent }) else { throw AdapterError.notInstalled(agent) }
        return adapter
    }

    /// The agent's storage folder, for showing plan paths relative to it.
    func root(for agent: AgentKind) -> URL {
        adapters.first { $0.kind == agent }?.root ?? claudeCode.root
    }

    // MARK: Derived

    var totalSessionBytes: Int64 { sessions.reduce(0) { $0 + $1.sizeBytes } }
    var totalFootprintBytes: Int64 { footprints.reduce(0) { $0 + $1.totalBytes } }
    var safeFootprintBytes: Int64 { footprints.reduce(0) { $0 + $1.bytes(.safe) } }
    /// Derived from `sessions` once per reload, so views reading them on every update (the
    /// sidebar, banners, the menu bar) do not refilter every session each time.
    private(set) var liveSessions: [Session] = []
    /// Expiring sessions per agent with a known rule, in sidebar order.
    private(set) var expiringByAgent: [(rule: RetentionRule, sessions: [Session])] = []
    /// Agents that have at least one session, in declaration order.
    private(set) var agentsPresent: [AgentKind] = []
    private var sessionCounts: [AgentKind: Int] = [:]
    private var hasExpiringSessions = false
    /// Bumped whenever `sessions` is replaced, so views can key on it instead of comparing
    /// every session.
    private(set) var revision = 0
    var needsAttention: Bool { hasExpiringSessions || hasDiskWarnings }

    /// Below this, disk use is not worth a warning in the menu bar.
    static let diskWarningBytes: Int64 = 500_000_000
    /// The Claude Desktop VM bundle's size, when it is big enough to mention.
    var largeVMBundleBytes: Int64? {
        category(.claudeDesktopVM).map(\.sizeBytes).flatMap { $0 > Self.diskWarningBytes ? $0 : nil }
    }
    var hasLargeSafeFootprint: Bool { safeFootprintBytes > Self.diskWarningBytes }
    var hasDiskWarnings: Bool { largeVMBundleBytes != nil || hasLargeSafeFootprint || hasLargeModelFootprint }

    func count(for agent: AgentKind) -> Int {
        sessionCounts[agent] ?? 0
    }

    /// Disk use per agent, largest first, for breakdown bars.
    var footprintByAgent: [(agent: AgentKind, bytes: Int64)] {
        footprints.map { ($0.agent, $0.totalBytes) }.sorted { $0.1 > $1.1 }
    }

    /// Days until the last of the expiring sessions is swept, rounded up; `nil` when the
    /// agent's rule is not a date (Antigravity's 500-conversation cap).
    func expiringWithinDays(_ sessions: [Session]) -> Int? {
        guard let latest = sessions.compactMap(\.expiresAt).max() else { return nil }
        return max(0, Int(ceil(latest.timeIntervalSinceNow / 86_400)))
    }

    /// Recomputes the stored summaries of `sessions` and `retentionRules`.
    private func updateDerived() {
        var counts: [AgentKind: Int] = [:]
        var expiring: [AgentKind: [Session]] = [:]
        var live: [Session] = []
        for session in sessions {
            counts[session.agent, default: 0] += 1
            if session.status == .expiring { expiring[session.agent, default: []].append(session) }
            if session.status == .live { live.append(session) }
        }
        sessionCounts = counts
        liveSessions = live
        updateMenuBarFigures()
        hasExpiringSessions = !expiring.isEmpty
        agentsPresent = AgentKind.allCases.filter { counts[$0] != nil }
        expiringByAgent = AgentKind.allCases.compactMap { agent in
            guard let sessions = expiring[agent], let rule = retentionRules[agent] else { return nil }
            return (rule, sessions)
        }
        revision += 1
    }

    private func updateMenuBarFigures() {
        let next = MenuBarFigures(totalBytes: totalFootprintBytes, safeBytes: safeFootprintBytes, liveSessions: liveSessions.count)
        if next != menuBarFigures { menuBarFigures = next }
    }

    // MARK: Loading

    func reload() async {
        isLoading = true
        let started = ContinuousClock.now
        defer {
            isLoading = false
            logger.info("Reload finished in \(ContinuousClock.now - started, privacy: .public)")
        }
        // Disk sizes, orphans, kept copies and every agent's sessions are read in parallel,
        // off the main actor. Sizes are published as soon as they are measured: the menu bar
        // shows them without waiting for the session scan.
        //
        // Aider has no index and looks in the project folders of the other agents' sessions:
        // it gets them from this scan instead of listing every agent a second time.
        let aider = adapters.compactMap { $0 as? AiderAdapter }
        let others = adapters.filter { !($0 is AiderAdapter) }
        // One agent failing must not hide the others.
        let scanningOthers = Task.detached {
            await withTaskGroup(of: AgentScan.self) { group in
                for adapter in others {
                    group.addTask { await AgentScan.run(adapter) }
                }
                var results: [AgentScan] = []
                for await scan in group { results.append(scan) }
                return results
            }
        }
        let projectPaths = Task.detached { await scanningOthers.value.flatMap { $0.sessions.compactMap(\.projectPath) } }
        for adapter in aider { adapter.useKnownProjects(projectPaths) }
        let scanning = Task.detached {
            var results = await scanningOthers.value
            for adapter in aider { results.append(await AgentScan.run(adapter)) }
            return results
        }
        // Aider's footprint waits for those paths, so it is measured after the others' sizes
        // are published.
        let providers = footprintProviders
        let measuring = Task.detached { await FootprintScanner.scan(providers.filter { !($0 is AiderAdapter) }) }
        let measuringAider = Task.detached { await FootprintScanner.scan(aider) }
        let claudeCode = adapters.contains { $0.kind == .claudeCode } ? self.claudeCode : nil
        let orphans = Task.detached { await claudeCode?.orphanReport() ?? .empty }
        let executor = self.executor
        let kept = Task.detached { (try? executor.purgePlan([.toolCopy]).totalBytes) ?? 0 }
        let herdrState = Task.detached { [herdrClient] in herdrClient.state() }
        let measured = await measuring.value
        footprints = measured.footprints
        logger.info("Disk sizes ready after \(ContinuousClock.now - started, privacy: .public)")
        let scanned = await scanning.value
        herdr = await herdrState.value ?? .empty
        let measuredAider = await measuringAider.value
        if !measuredAider.footprints.isEmpty {
            let order = providers.map(\.kind)
            footprints = (measured.footprints + measuredAider.footprints)
                .sorted { (order.firstIndex(of: $0.agent) ?? .max) < (order.firstIndex(of: $1.agent) ?? .max) }
        }
        var found: [Session] = []
        var failures: [String] = []
        var readOnly: [AgentKind: String] = [:]
        for scan in scanned {
            found += scan.sessions
            if let reason = scan.readOnlyReason { readOnly[scan.kind] = reason }
            if let failure = scan.failure {
                logger.error("Scan of \(scan.kind.displayName, privacy: .public) failed: \(failure, privacy: .private)")
                failures.append(failure)
            }
        }
        orphanReport = await orphans.value
        keptCopyBytes = await kept.value
        failures += measured.failures + measuredAider.failures
        sessions = found.sorted { $0.lastActive > $1.lastActive }
        readOnlyAgents = readOnly
        var rules: [AgentKind: RetentionRule] = [:]
        for case let reporter as any RetentionReporting & AgentAdapter in adapters {
            if let rule = reporter.retentionRule() { rules[reporter.kind] = rule }
        }
        retentionRules = rules
        updateDerived()
        transcriptSearch.sessionsChanged(sessions, adapters: adapters)
        refreshTokens()
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: " ")
        lastScan = Date()
    }

    /// One agent's part of a reload, run off the main actor.
    private struct AgentScan: Sendable {
        let kind: AgentKind
        var sessions: [Session] = []
        var readOnlyReason: String?
        var failure: String?

        static func run(_ adapter: any AgentAdapter) async -> AgentScan {
            var scan = AgentScan(kind: adapter.kind)
            let status = await adapter.status()
            guard status != .notInstalled else { return scan }
            if case .readOnly(let reason) = status { scan.readOnlyReason = reason }
            do {
                scan.sessions = try await adapter.sessions()
            } catch {
                scan.failure = FullDiskAccess.explain(error, agent: adapter.kind)
            }
            return scan
        }
    }

    /// The newest `limit` messages before `cursor` (`nil`: the end) for the preview, with the
    /// values of scan findings masked.
    func transcriptPage(of session: Session, limit: Int = 200, before cursor: TranscriptCursor?) async throws -> Transcript {
        try await adapter(for: session.agent).transcriptPage(of: session, limit: limit, before: cursor, masking: findings(for: session))
    }

    func artifacts(of session: Session) async throws -> [Artifact] {
        try await adapter(for: session.agent).artifacts(of: session)
    }

    // MARK: Plans

    func deletePlan(for session: Session, destination: Destination) async throws -> Plan {
        let plan = try await adapter(for: session.agent).deletePlan(for: session, destination: destination)
        return await currentHerdr().markingLive(plan, for: session)
    }

    /// Delete plans for a batch, in order, each agent asked once for all of its sessions.
    func deletePlans(for sessions: [Session], destination: Destination) async -> [PlannedSession] {
        var results: [Session.ID: PlannedSession] = [:]
        for (agent, group) in Dictionary(grouping: sessions, by: \.agent) {
            do {
                for planned in try await adapter(for: agent).deletePlans(for: group, destination: destination) {
                    results[planned.session.id] = planned
                }
            } catch {
                for session in group { results[session.id] = PlannedSession(session: session, result: .failure(error)) }
            }
        }
        let herdr = await currentHerdr()
        return sessions.compactMap { session in
            results[session.id].map { PlannedSession(session: session, result: $0.result.map { herdr.markingLive($0, for: session) }) }
        }
    }

    /// One archive plan per session; sessions with nothing to do are left out. A batch also
    /// leaves out blocked plans; a single plan, blocked or empty, stays so the sheet can say why.
    /// Each agent is asked once for all of its sessions.
    func archivePlans(for sessions: [Session]) async throws -> [Plan] {
        let candidates = sessions.filter { $0.status != .live }
        var results: [Session.ID: Result<Plan, any Error>] = [:]
        for (agent, group) in Dictionary(grouping: candidates, by: \.agent) {
            do {
                for planned in try await adapter(for: agent).archivePlans(for: group) {
                    results[planned.session.id] = planned.result
                }
            } catch {
                for session in group { results[session.id] = .failure(error) }
            }
        }
        var plans: [Plan] = []
        let herdr = await currentHerdr()
        for session in candidates {
            guard let found = try results[session.id]?.get() else { continue }
            let plan = herdr.markingLive(found, for: session)
            if sessions.count == 1 || (!plan.isEmpty && !plan.liveCheck.isLive) { plans.append(plan) }
        }
        return plans
    }

    /// Executes a delete plan off the main actor, then rescans and offers undo.
    func execute(_ plan: Plan, for session: Session, purgeNow: Bool = false) async throws {
        var plan = plan
        // The undo entry remembers the scan's verdict, so Purge originals can offer its files.
        plan.secretFindingCount = secretFindings[session.id]?.count ?? 0
        let entries = try await run([plan])
        secretFindings[session.id] = nil
        let size = plan.totalBytes.formatted(.byteCount(style: .file))
        let freed = purgeNow ? await purgeKeptCopies(entries) : nil
        let action = UndoAction(name: "Move to Trash", entries: entries)
        if freed == nil { register(action) }
        let title = "\u{201C}\(session.displayTitle)\u{201D} (\(size))"
        let destination = (plan.destination ?? .trash).displayName
        let message: String
        if !plan.commands.isEmpty {
            message = "Deleted \(title) with \(plan.commands.map { "`\($0.executable.lastPathComponent) \($0.arguments.first ?? "")`" }.joined(separator: ", "))."
        } else if let edit = plan.databaseEdits.first(where: { !$0.isEmpty }) {
            message = "Deleted \(title) from \(edit.database.lastPathComponent); the database passed its integrity check."
        } else {
            message = "Moved \(title) to \(destination)."
        }
        toast = Toast(message: message + (freed.map { " " + $0 } ?? "") + Self.leftoverText(entries), undo: freed == nil ? action : nil)
        await reload()
    }

    /// Executes delete plans for several sessions as one batch: one undo entry for all.
    func execute(_ plans: [Plan], for sessions: [Session], purgeNow: Bool = false) async throws {
        if plans.count == 1, let session = sessions.first(where: { $0.id == plans[0].sessionID }) {
            try await execute(plans[0], for: session, purgeNow: purgeNow)
            return
        }
        let plans = plans.map { plan in
            var plan = plan
            plan.secretFindingCount = secretFindings[plan.sessionID]?.count ?? 0
            return plan
        }
        let entries = try await run(plans)
        for plan in plans { secretFindings[plan.sessionID] = nil }
        let size = plans.reduce(Int64(0)) { $0 + $1.totalBytes }.formatted(.byteCount(style: .file))
        let freed = purgeNow ? await purgeKeptCopies(entries) : nil
        let action = UndoAction(name: "Move to Trash", entries: entries)
        if freed == nil { register(action) }
        let what = "\(plans.count) sessions (\(size))"
        let message = plans.allSatisfy(\.moves.isEmpty)
            ? "Deleted \(what)."
            : "Moved \(what) to \((plans[0].destination ?? .trash).displayName)."
        toast = Toast(message: message + (freed.map { " " + $0 } ?? "") + Self.leftoverText(entries), undo: freed == nil ? action : nil)
        await reload()
    }

    /// Runs a confirmed action without holding the sheet open. Jobs run one after another, so
    /// two never write the undo log at once; the executor still checks each session is not
    /// in use right before touching it.
    func runInBackground(_ activity: String, status: String, sessions ids: [Session.ID], _ work: @escaping @MainActor () async throws -> Void) {
        for id in ids { busySessions[id] = status }
        let previous = backgroundJob
        backgroundJob = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            backgroundActivity = activity
            do {
                try await work()
            } catch {
                actionError = error.localizedDescription
            }
            for id in ids { busySessions[id] = nil }
            backgroundActivity = nil
        }
    }

    /// "Free the space now": purges the copies Domovy kept for `entries` right after the tool
    /// command ran. Returns what to tell the user; a failure leaves the copies and says so.
    func purgeKeptCopies(_ entries: [UndoEntry]) async -> String {
        let executor = self.executor
        do {
            let plan = try await Task.detached { try executor.purgeKeptCopies(of: entries) }.value
            guard !plan.isEmpty else { return "Domovy kept no copy, so there was nothing more to free." }
            return "Freed \(plan.totalBytes.formatted(.byteCount(style: .file))) now; this can't be undone."
        } catch {
            logger.error("Purging kept copies failed: \(error.localizedDescription, privacy: .private)")
            return "Domovy could not delete its copy (\(error.localizedDescription)); purge it later from the Disk screen."
        }
    }

    /// Executes archive plans as one batch, then rescans and offers undo.
    func archive(_ plans: [Plan]) async throws {
        let entries = try await run(plans)
        let done = Set(entries.flatMap(\.compressed).map(\.file))
        let items = plans.flatMap(\.compressions).filter { done.contains($0.file) }
        let before = items.reduce(Int64(0)) { $0 + $1.sizeBytes }.formatted(.byteCount(style: .file))
        let after = items.reduce(Int64(0)) { $0 + $1.estimatedBytes }.formatted(.byteCount(style: .file))
        let what = plans.count == 1
            ? "\u{201C}\(sessions.first { $0.id == plans[0].sessionID }?.displayTitle ?? "session")\u{201D}"
            : "\(plans.count) sessions"
        let action = UndoAction(name: "Archive", entries: entries)
        let ranCommands = plans.contains { !$0.commands.isEmpty }
        let message: String
        if ranCommands {
            message = items.isEmpty ? "Archived \(what)." : "Archived \(what); compressed \(before) \u{2192} ~\(after)."
        } else {
            message = items.isEmpty ? "Nothing in \(what) needed compressing." : "Archived \(what) (\(before) \u{2192} ~\(after))."
        }
        let undoable = !items.isEmpty || ranCommands
        if undoable { register(action) }
        toast = Toast(message: message + Self.leftoverText(entries), undo: undoable ? action : nil)
        await reload()
    }

    /// Reverts one Domovy action, newest entry first. Called by ⌘Z and by the toast.
    func undo(_ action: UndoAction) async throws {
        undoManager?.removeAllActions(withTarget: action)
        // An archive or delete still running in the background finishes first.
        await backgroundJob?.value
        let executor = self.executor
        // The executor reads each entry again from disk: `domo` or another undo may have
        // undone one of them since, which is skipped rather than undone twice.
        let restored = try await Task.detached {
            try action.entries.reversed().compactMap { entry -> UndoEntry? in
                do { return try executor.undo(entry) } catch ExecutorError.alreadyUndone { return nil }
            }
        }.value
        let titles = Set(restored.map(\.sessionID)).compactMap { id in sessions.first { $0.id == id }?.displayTitle }
        let what: String
        if let cleanup = restored.first.flatMap({ CleanupID(rawValue: $0.sessionID) }) {
            what = cleanup.undoName
        } else if restored.first?.agent.isModelStore == true {
            what = restored.map(\.sessionID).joined(separator: ", ")
        } else if let scope = restored.first.flatMap({ OrphanScope(rawValue: $0.sessionID) }) {
            what = scope == .orphans ? "the orphans" : "the duplicates"
        } else {
            what = titles.count == 1 ? "\u{201C}\(titles[0])\u{201D}" : "\(Set(restored.map(\.sessionID)).count) sessions"
        }
        let verb = switch action.entries.first?.action {
        case .archive: "Decompressed"
        case .redact: "Put back the original of"
        default: "Put back"
        }
        toast = Toast(message: "\(verb) \(what).", undo: nil)
        registeredUndoActions.removeAll { $0 === action }
        await reload()
        if action.entries.first?.action == .redact {
            await rescanSecrets(Set(restored.map(\.sessionID)))
        }
    }

    /// " Checked afterwards: …" after a verified agent command, and how its copy was kept when
    /// that is worth knowing (a full copy instead of a clone), or nothing.
    static func leftoverText(_ entries: [UndoEntry]) -> String {
        let notes = entries.flatMap(\.notes)
        let leftovers = entries.flatMap(\.leftovers)
        return (notes.isEmpty ? "" : " " + notes.joined(separator: " "))
            + (leftovers.isEmpty ? "" : " Checked afterwards: " + leftovers.joined(separator: " "))
    }

    /// Executes plans off the main actor. When one stops half way, what already changed stays
    /// in the undo log, and ⌘Z or the toast puts it back.
    func run(_ plans: [Plan]) async throws -> [UndoEntry] {
        let executor = self.executor
        do {
            return try await Task.detached { try executor.execute(plans) }.value
        } catch {
            let ids = Set(plans.map(\.id))
            let partial = (try? await Task.detached { try executor.undoLog.entries() }.value)?
                .filter { ids.contains($0.planID) && $0.hasChangesToUndo } ?? []
            if !partial.isEmpty {
                let action = UndoAction(name: "Partial Change", entries: partial)
                register(action)
                toast = Toast(message: "It stopped part way. Undo puts back what already changed.", undo: action)
            }
            throw error
        }
    }

    func register(_ action: UndoAction) {
        registeredUndoActions.append(action)
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: action) { [weak self] action in
            Task { @MainActor in
                do { try await self?.undo(action) } catch { self?.actionError = error.localizedDescription }
            }
        }
        undoManager.setActionName(action.name)
    }
}

extension Session {
    /// "Also in Claude Desktop's session list (archived there)."
    var desktopHelp: String? {
        guard let desktop else { return nil }
        return "Also in Claude Desktop's session list" + (desktop.isArchived ? ", archived there." : ".")
    }
    var sortProject: String { projectName ?? "" }

    /// OpenCode sessions and Cursor's editor chats are rows of one shared database: there is no
    /// file to compress.
    var canArchive: Bool { agent != .openCode && !CursorAdapter.isEditorChat(self) }

    /// Whole days until the agent's sweep, for the status column and warnings.
    var daysUntilExpiry: Int? {
        expiresAt.map { max(0, Int(ceil($0.timeIntervalSinceNow / 86_400))) }
    }
}
