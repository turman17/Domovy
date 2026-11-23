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

    let adapter: ClaudeCodeAdapter
    let executor: Executor
    private let logger = Logger(subsystem: "io.github.turman17.Domovy", category: "SessionLibrary")

    init(home: URL, storeRoot: URL) {
        adapter = ClaudeCodeAdapter(home: home)
        executor = Executor(storeRoot: storeRoot)
    }

    // MARK: Derived

    var totalSessionBytes: Int64 { sessions.reduce(0) { $0 + $1.sizeBytes } }
    var totalFootprintBytes: Int64 { footprints.reduce(0) { $0 + $1.totalBytes } }
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
        do {
            sessions = try await adapter.sessions()
            footprints = [try await adapter.footprint()]
            retentionDays = adapter.cleanupPeriodDays()
            errorMessage = nil
            lastScan = Date()
        } catch {
            logger.error("Scan failed: \(error.localizedDescription, privacy: .private)")
            errorMessage = error.localizedDescription
        }
    }

    func transcript(of session: Session) async throws -> Transcript {
        try await adapter.transcript(of: session, limit: 200)
    }

    func artifacts(of session: Session) async throws -> [Artifact] {
        try await adapter.artifacts(of: session)
    }

    // MARK: Plans

    func deletePlan(for session: Session, destination: Destination) async throws -> Plan {
        try await adapter.deletePlan(for: session, destination: destination)
    }

    /// One archive plan per session; sessions with nothing to compress are left out.
    func archivePlans(for sessions: [Session]) async throws -> [Plan] {
        var plans: [Plan] = []
        for session in sessions where session.status != .live {
            let plan = try await adapter.archivePlan(for: session)
            if !plan.isEmpty, !plan.liveCheck.isLive { plans.append(plan) }
        }
        return plans
    }

    /// Executes a delete plan off the main actor, then rescans and offers undo.
    func execute(_ plan: Plan, for session: Session) async throws {
        let entries = try await run([plan])
        let size = plan.totalBytes.formatted(.byteCount(style: .file))
        let action = UndoAction(name: "Move to Trash", entries: entries)
        register(action)
        toast = Toast(message: "Moved \u{201C}\(session.displayTitle)\u{201D} (\(size)) to \((plan.destination ?? .trash).displayName).", undo: action)
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
        register(action)
        toast = Toast(message: items.isEmpty ? "Nothing in \(what) needed compressing." : "Archived \(what) (\(before) \u{2192} ~\(after)).", undo: items.isEmpty ? nil : action)
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
        let what = titles.count == 1 ? "\u{201C}\(titles[0])\u{201D}" : "\(restored.count) sessions"
        let verb = action.entries.first?.action == .archive ? "Decompressed" : "Put back"
        toast = Toast(message: "\(verb) \(what).", undo: nil)
        await reload()
    }

    private func run(_ plans: [Plan]) async throws -> [UndoEntry] {
        let executor = self.executor
        return try await Task.detached { try executor.execute(plans) }.value
    }

    private func register(_ action: UndoAction) {
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
    var sortProject: String { projectName ?? "" }

    /// Whole days until the agent's sweep, for the status column and warnings.
    var daysUntilExpiry: Int? {
        expiresAt.map { max(0, Int(ceil($0.timeIntervalSinceNow / 86_400))) }
    }
}
