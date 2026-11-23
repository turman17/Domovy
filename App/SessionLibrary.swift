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

/// A short confirmation after an action, with the undo entry it can revert.
struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let undoEntry: UndoEntry?

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
    private(set) var canUndo = false
    var toast: Toast?
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
        refreshUndoState()
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

    /// Executes off the main actor, then rescans and offers undo.
    func execute(_ plan: Plan, for session: Session) async throws {
        let executor = self.executor
        let entry = try await Task.detached { try executor.execute(plan) }.value
        let size = plan.totalBytes.formatted(.byteCount(style: .file))
        toast = Toast(message: "Moved \u{201C}\(session.displayTitle)\u{201D} (\(size)) to \(plan.destination.displayName).", undoEntry: entry)
        await reload()
    }

    func undo(_ entry: UndoEntry? = nil) async throws {
        let executor = self.executor
        let restored = try await Task.detached {
            if let entry { return try executor.undo(entry) }
            return try executor.undoLatest()
        }.value
        let title = sessions.first { $0.id == restored.sessionID }?.displayTitle ?? "session"
        toast = Toast(message: "Put \u{201C}\(title)\u{201D} back.", undoEntry: nil)
        await reload()
    }

    private func refreshUndoState() {
        canUndo = ((try? executor.undoLog.latestPending()) ?? nil) != nil
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
