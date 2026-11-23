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
    /// Last measured footprints, kept while a rescan runs so the Disk screen never goes blank.
    private(set) var footprints: [Footprint] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastScan: Date?
    /// Each agent's own retention sweep, for the banner and the menu bar.
    private(set) var retentionRules: [AgentKind: RetentionRule] = [:]
    /// Agents Domovy only reads, with the reason (Antigravity for now).
    private(set) var readOnlyAgents: [AgentKind: String] = [:]
    var toast: Toast?
    /// Failure of an action started from the menu (⌘Z), shown by the sessions view.
    var actionError: String?
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

    let claudeCode: ClaudeCodeAdapter
    let codex: CodexAdapter
    /// Every adapter, in sidebar order. Agents not installed at this home are skipped on scan.
    let adapters: [any AgentAdapter]
    /// Every agent the Disk screen measures: the adapters plus Claude Desktop.
    let footprintProviders: [any FootprintProvider]
    let executor: Executor
    /// The Disk screen's guided cleanups.
    let cleanupPlanner: CleanupPlanner
    let home: URL
    let logger = Logger(subsystem: "io.github.turman17.Domovy", category: "SessionLibrary")

    init(home: URL, storeRoot: URL, isCustomHome: Bool) {
        self.home = home
        claudeCode = ClaudeCodeAdapter(home: home)
        codex = CodexAdapter(home: home, cli: CodexCLI.choice(home: home, isCustomHome: isCustomHome))
        adapters = [
            claudeCode, codex,
            GeminiAdapter(home: home),
            AntigravityAdapter(home: home),
            OpenCodeAdapter(home: home, cli: OpenCodeCLI.choice(home: home, isCustomHome: isCustomHome)),
            CopilotAdapter(home: home),
            CursorAdapter(home: home),
        ]
        let models = ModelStores.at(home: home, isCustomHome: isCustomHome)
        footprintProviders = adapters + FootprintScanner.measuredOnly(home: home) + FootprintScanner.modelStores(models)
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
    var expiringSessions: [Session] { sessions.filter { $0.status == .expiring } }
    var liveSessions: [Session] { sessions.filter { $0.status == .live } }
    var needsAttention: Bool { !expiringSessions.isEmpty || hasDiskWarnings }

    /// Below this, disk use is not worth a warning in the menu bar.
    static let diskWarningBytes: Int64 = 500_000_000
    /// The Claude Desktop VM bundle's size, when it is big enough to mention.
    var largeVMBundleBytes: Int64? {
        category(.claudeDesktopVM).map(\.sizeBytes).flatMap { $0 > Self.diskWarningBytes ? $0 : nil }
    }
    var hasLargeSafeFootprint: Bool { safeFootprintBytes > Self.diskWarningBytes }
    var hasDiskWarnings: Bool { largeVMBundleBytes != nil || hasLargeSafeFootprint || hasLargeModelFootprint }

    /// Agents that have at least one session, in declaration order.
    var agentsPresent: [AgentKind] {
        AgentKind.allCases.filter { kind in sessions.contains { $0.agent == kind } }
    }

    func count(for agent: AgentKind) -> Int {
        sessions.filter { $0.agent == agent }.count
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

    /// Expiring sessions per agent with a known rule, in sidebar order.
    var expiringByAgent: [(rule: RetentionRule, sessions: [Session])] {
        AgentKind.allCases.compactMap { agent in
            let expiring = expiringSessions.filter { $0.agent == agent }
            guard !expiring.isEmpty, let rule = retentionRules[agent] else { return nil }
            return (rule, expiring)
        }
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
        let providers = footprintProviders
        let measuring = Task.detached { await FootprintScanner.scan(providers) }
        let claudeCode = self.claudeCode
        let orphans = Task.detached { await claudeCode.orphanReport() }
        let executor = self.executor
        let kept = Task.detached { (try? executor.purgePlan([.toolCopy]).totalBytes) ?? 0 }
        let adapters = self.adapters
        // One agent failing must not hide the others.
        let scanning = Task.detached {
            await withTaskGroup(of: AgentScan.self) { group in
                for adapter in adapters {
                    group.addTask { await AgentScan.run(adapter) }
                }
                var results: [AgentScan] = []
                for await scan in group { results.append(scan) }
                return results
            }
        }
        let measured = await measuring.value
        footprints = measured.footprints
        logger.info("Disk sizes ready after \(ContinuousClock.now - started, privacy: .public)")
        let scanned = await scanning.value
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
        failures += measured.failures
        sessions = found.sorted { $0.lastActive > $1.lastActive }
        readOnlyAgents = readOnly
        var rules: [AgentKind: RetentionRule] = [:]
        for case let reporter as any RetentionReporting & AgentAdapter in adapters {
            if let rule = reporter.retentionRule() { rules[reporter.kind] = rule }
        }
        retentionRules = rules
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
                scan.failure = error.localizedDescription
            }
            return scan
        }
    }

    /// The conversation for the preview, with the values of scan findings masked.
    func transcript(of session: Session) async throws -> Transcript {
        try await adapter(for: session.agent).transcript(of: session, limit: 200, masking: findings(for: session))
    }

    func artifacts(of session: Session) async throws -> [Artifact] {
        try await adapter(for: session.agent).artifacts(of: session)
    }

    // MARK: Plans

    func deletePlan(for session: Session, destination: Destination) async throws -> Plan {
        try await adapter(for: session.agent).deletePlan(for: session, destination: destination)
    }

    /// One archive plan per session; sessions with nothing to do are left out. A batch also
    /// leaves out blocked plans; a single blocked plan stays so the sheet can say why.
    func archivePlans(for sessions: [Session]) async throws -> [Plan] {
        var plans: [Plan] = []
        for session in sessions where session.status != .live {
            let plan = try await adapter(for: session.agent).archivePlan(for: session)
            if !plan.isEmpty, sessions.count == 1 || !plan.liveCheck.isLive { plans.append(plan) }
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
            what = titles.count == 1 ? "\u{201C}\(titles[0])\u{201D}" : "\(restored.count) sessions"
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
    /// The first prompt as plain text: markdown markers and paste placeholders removed.
    var displayTitle: String {
        guard var text = title else { return "Untitled session" }
        if text.contains("<pasted_content") || text.contains("</pasted_content>") {
            text = text.replacingOccurrences(of: #"</?pasted_content[^>]*>?"#, with: " ", options: .regularExpression)
        }
        if text.contains("**") || text.contains("`") || text.contains("__") {
            text = text.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Pasted text" : text
    }

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
