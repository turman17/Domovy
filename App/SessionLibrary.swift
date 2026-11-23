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
    private(set) var retentionDays = 30
    var toast: Toast?
    /// Failure of an action started from the menu (⌘Z), shown by the sessions view.
    var actionError: String?
    /// The main window's undo manager. Domovy actions go on the same stack as text edits, so
    /// ⌘Z in the search field undoes typing and ⌘Z elsewhere undoes the last Domovy action.
    weak var undoManager: UndoManager?
    /// Set by the menu bar popover so the main window opens on that filter.
    var requestedFilter: StatusFilter?

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

    let claudeCode: ClaudeCodeAdapter
    let codex: CodexAdapter
    /// Every adapter, in sidebar order. Agents not installed at this home are skipped on scan.
    let adapters: [any AgentAdapter]
    /// Every agent the Disk screen measures: the adapters plus Claude Desktop and Cursor.
    let footprintProviders: [any FootprintProvider]
    let executor: Executor
    let home: URL
    let logger = Logger(subsystem: "io.github.turman17.Domovy", category: "SessionLibrary")

    init(home: URL, storeRoot: URL, isCustomHome: Bool) {
        self.home = home
        claudeCode = ClaudeCodeAdapter(home: home)
        codex = CodexAdapter(home: home, cli: CodexCLI.choice(home: home, isCustomHome: isCustomHome))
        adapters = [claudeCode, codex]
        footprintProviders = adapters + FootprintScanner.measuredOnly(home: home)
        executor = Executor(storeRoot: storeRoot)
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
    var needsAttention: Bool { !expiringSessions.isEmpty }

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

    /// Days until the last of the expiring sessions is swept, rounded up.
    var expiringWithinDays: Int {
        guard let latest = expiringSessions.compactMap(\.expiresAt).max() else { return 0 }
        return max(0, Int(ceil(latest.timeIntervalSinceNow / 86_400)))
    }

    // MARK: Loading

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        // Disk sizes are measured off the main actor, alongside the session scan.
        let providers = footprintProviders
        let measuring = Task.detached { await FootprintScanner.scan(providers) }
        var found: [Session] = []
        var failures: [String] = []
        // One agent failing must not hide the others.
        for adapter in adapters where await adapter.status() != .notInstalled {
            do {
                found += try await adapter.sessions()
            } catch {
                logger.error("Scan of \(adapter.kind.displayName, privacy: .public) failed: \(error.localizedDescription, privacy: .private)")
                failures.append(error.localizedDescription)
            }
        }
        let claudeCode = self.claudeCode
        let orphans = Task.detached { await claudeCode.orphanReport() }
        let measured = await measuring.value
        orphanReport = await orphans.value
        failures += measured.failures
        sessions = found.sorted { $0.lastActive > $1.lastActive }
        footprints = measured.footprints
        retentionDays = claudeCode.cleanupPeriodDays()
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: " ")
        lastScan = Date()
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
    func execute(_ plan: Plan, for session: Session) async throws {
        var plan = plan
        // The undo entry remembers the scan's verdict, so Purge originals can offer its files.
        plan.secretFindingCount = secretFindings[session.id]?.count ?? 0
        let entries = try await run([plan])
        secretFindings[session.id] = nil
        let size = plan.totalBytes.formatted(.byteCount(style: .file))
        let action = UndoAction(name: "Move to Trash", entries: entries)
        register(action)
        let title = "\u{201C}\(session.displayTitle)\u{201D} (\(size))"
        let destination = (plan.destination ?? .trash).displayName
        let message = plan.commands.isEmpty
            ? "Moved \(title) to \(destination)."
            : "Deleted \(title) with \(plan.commands.map { "`\($0.executable.lastPathComponent) \($0.arguments.first ?? "")`" }.joined(separator: ", "))."
        toast = Toast(message: message + Self.leftoverText(entries), undo: action)
        await reload()
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
        let restored = try await Task.detached {
            try action.entries.reversed().filter { !$0.isUndone }.map { try executor.undo($0) }
        }.value
        let titles = Set(restored.map(\.sessionID)).compactMap { id in sessions.first { $0.id == id }?.displayTitle }
        let what: String
        if let scope = restored.first.flatMap({ OrphanScope(rawValue: $0.sessionID) }) {
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

    /// " Codex left 2 things behind: …" after a verified agent command, or nothing.
    static func leftoverText(_ entries: [UndoEntry]) -> String {
        let leftovers = entries.flatMap(\.leftovers)
        guard !leftovers.isEmpty else { return "" }
        return " Checked afterwards: " + leftovers.joined(separator: " ")
    }

    func run(_ plans: [Plan]) async throws -> [UndoEntry] {
        let executor = self.executor
        return try await Task.detached { try executor.execute(plans) }.value
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
    var displayTitle: String { title ?? "Untitled session" }

    /// "Also in Claude Desktop's session list (archived there)."
    var desktopHelp: String? {
        guard let desktop else { return nil }
        return "Also in Claude Desktop's session list" + (desktop.isArchived ? ", archived there." : ".")
    }
    var sortProject: String { projectName ?? "" }

    /// Whole days until the agent's sweep, for the status column and warnings.
    var daysUntilExpiry: Int? {
        expiresAt.map { max(0, Int(ceil($0.timeIntervalSinceNow / 86_400))) }
    }
}
