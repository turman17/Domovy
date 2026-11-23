import Foundation

/// A guided cleanup on the Disk screen (PLAN.md section 4 B). The raw value is the id
/// `domo clean <id>` takes and `domo du --ids` lists.
public enum CleanupID: String, CaseIterable, Codable, Sendable {
    case claudeDesktopVM = "claude-desktop-vm"
    case claudeDesktopCaches = "claude-desktop-caches"
    case claudeCodeAgentSDK = "claude-code-agent-sdk"
    case claudeCodeWorktrees = "claude-code-worktrees"
    case codexLogs = "codex-logs"
    case codexLargeRollouts = "codex-large-rollouts"
    case codexWorktrees = "codex-worktrees"

    public var agent: AgentKind {
        switch self {
        case .claudeDesktopVM, .claudeDesktopCaches: .claudeDesktop
        case .claudeCodeAgentSDK, .claudeCodeWorktrees: .claudeCode
        case .codexLogs, .codexLargeRollouts, .codexWorktrees: .codex
        }
    }

    /// Compresses in place instead of moving anything.
    public var compresses: Bool { self == .codexLargeRollouts }

    /// The question at the top of the plan sheet.
    public var title: String {
        switch self {
        case .claudeDesktopVM: "Remove the Claude Desktop VM bundle?"
        case .claudeDesktopCaches: "Clear Claude Desktop's caches?"
        case .claudeCodeAgentSDK: "Remove the Agent SDK environment?"
        case .claudeCodeWorktrees: "Remove merged Claude Code worktrees?"
        case .codexLogs: "Remove the Codex logs database?"
        case .codexLargeRollouts: "Compress large Codex rollouts?"
        case .codexWorktrees: "Remove merged Codex worktrees?"
        }
    }

    /// The Disk row's button.
    public var buttonTitle: String {
        switch self {
        case .claudeDesktopVM, .claudeCodeWorktrees, .codexWorktrees: "Review\u{2026}"
        case .codexLargeRollouts: "Compress\u{2026}"
        case .claudeDesktopCaches, .claudeCodeAgentSDK, .codexLogs: "Clean Up\u{2026}"
        }
    }

    /// For the undo toast: "Put back the Claude Desktop VM bundle."
    public var undoName: String {
        switch self {
        case .claudeDesktopVM: "the Claude Desktop VM bundle"
        case .claudeDesktopCaches: "Claude Desktop's caches"
        case .claudeCodeAgentSDK: "the Agent SDK environment"
        case .claudeCodeWorktrees: "the Claude Code worktrees"
        case .codexLogs: "the Codex logs database"
        case .codexLargeRollouts: "the large Codex rollouts"
        case .codexWorktrees: "the Codex worktrees"
        }
    }
}

/// Something a cleanup looked at and leaves as it is, with the reason.
public struct CleanupExclusion: Hashable, Codable, Sendable {
    public let url: URL
    public let sizeBytes: Int64
    public let reason: String

    public init(url: URL, sizeBytes: Int64, reason: String) {
        self.url = url
        self.sizeBytes = sizeBytes
        self.reason = reason
    }
}

/// A cleanup's plan plus what it leaves alone. `plan` is what the executor runs; the same
/// value drives the sheet and `domo clean --dry-run`.
public struct CleanupPlan: Identifiable, Hashable, Sendable {
    public let cleanup: CleanupID
    public let plan: Plan
    public let excluded: [CleanupExclusion]
    /// Whether the Disk row is "consequences": the sheet's button is then the red one.
    public let hasConsequences: Bool

    public init(cleanup: CleanupID, plan: Plan, excluded: [CleanupExclusion], hasConsequences: Bool) {
        self.cleanup = cleanup
        self.plan = plan
        self.excluded = excluded
        self.hasConsequences = hasConsequences
    }

    public var id: UUID { plan.id }
    public var isBlocked: Bool { plan.liveCheck.isLive }
    public var canExecute: Bool { !isBlocked && !plan.isEmpty }

    /// "Moves 3 folders (6.3 MB) to the Trash. You can undo this."
    public var summary: String {
        if isBlocked { return "Nothing will change yet. " + plan.liveCheck.reasons.joined(separator: " ") }
        if cleanup.compresses {
            guard !plan.compressions.isEmpty else { return "Nothing to compress: every large rollout is already compressed or in use." }
            let n = plan.compressions.count
            return "Compresses \(n) \(n == 1 ? "rollout" : "rollouts") in place (\(Self.bytes(plan.totalBytes)) \u{2192} ~\(Self.bytes(plan.estimatedBytesAfter)) on disk). Codex can still resume them. You can undo this."
        }
        guard !plan.moves.isEmpty else { return "Nothing to remove." }
        let n = plan.moves.count
        let noun: String
        if plan.moves.allSatisfy({ $0.kind == .folder }) {
            noun = n == 1 ? "folder" : "folders"
        } else if plan.moves.allSatisfy({ $0.kind == .file }) {
            noun = n == 1 ? "file" : "files"
        } else {
            noun = n == 1 ? "item" : "items"
        }
        return "Moves \(n) \(noun) (\(Self.bytes(plan.totalBytes))) to \((plan.destination ?? .trash).displayName). You can undo this."
    }

    static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: count)
    }
}

public enum CleanupError: Error, LocalizedError, Hashable, Sendable {
    /// Something started using the files after the plan was made.
    case inUse(reasons: [String])
    case notFound(CleanupID)

    public var errorDescription: String? {
        switch self {
        case .inUse(let reasons):
            "Nothing was changed. " + reasons.joined(separator: " ")
        case .notFound(let id):
            "There is nothing to clean up for \(id.rawValue) at this location."
        }
    }
}
