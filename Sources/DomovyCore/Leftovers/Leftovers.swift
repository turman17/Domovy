import Foundation

/// A folder of build output that a tool recreates on the next install or build.
public enum BuildOutputKind: String, CaseIterable, Codable, Sendable {
    case nodeModules = "node_modules"
    case swiftBuild = ".build"
    case cargoTarget = "target"
    case derivedData = "DerivedData"
    case dist = "dist"
    case nextBuild = ".next"
    case pythonCache = "__pycache__"
    case virtualEnvironment = ".venv"

    /// The folder name, which is also how it is found.
    public var folderName: String { rawValue }

    /// One line: what it is and what puts it back.
    public var explanation: String {
        switch self {
        case .nodeModules: "JavaScript packages. npm, pnpm or yarn install puts them back."
        case .swiftBuild: "Swift Package Manager build products. The next swift build recreates them."
        case .cargoTarget: "Rust or Maven build products. The next cargo build or mvn package recreates them."
        case .derivedData: "Xcode build products kept in the repository. The next build recreates them."
        case .dist: "Bundled output. The project's build script recreates it."
        case .nextBuild: "Next.js build cache. next build or next dev recreates it."
        case .pythonCache: "Compiled Python bytecode. Python recreates it on the next run."
        case .virtualEnvironment: "Python virtual environment. uv sync or pip install recreates it."
        }
    }
}

/// One build output folder in an agent worktree or a project an agent worked in.
public struct BuildOutput: Identifiable, Hashable, Sendable {
    public let url: URL
    public let kind: BuildOutputKind
    public let sizeBytes: Int64
    /// The checkout it belongs to: a worktree or the project folder.
    public let checkout: URL
    /// The checkout is the main checkout or a plain project folder, not an agent worktree.
    public let isInMainCheckout: Bool
    /// Why it cannot be removed right now (a live session, a process working there).
    public let inUse: String?

    public var id: URL { url }
    public var isRemovable: Bool { inUse == nil }
}

/// A linked git worktree an agent created or worked in.
public struct AgentWorktree: Identifiable, Hashable, Sendable {
    public enum State: Hashable, Sendable {
        /// Clean, and its commits are on a branch. Offered for removal.
        case leftover(String)
        /// Holds work that exists nowhere else: uncommitted changes, files git ignores that are
        /// not build output, or commits on no branch. Kept unless the user includes it explicitly.
        case hasWork(String)
        /// A live session, a process working in it or an open file. Never offered.
        case inUse(String)
        /// Locked, or git could not read it. Never offered.
        case keep(String)

        public var reason: String {
            switch self {
            case .leftover(let text), .hasWork(let text), .inUse(let text), .keep(let text): text
            }
        }
    }

    public let url: URL
    /// The main checkout of its repository; `nil` when git could not tell.
    public let repository: URL?
    /// The agent whose folder it is in or whose sessions ran in it.
    public let agent: AgentKind?
    /// `refs/heads/` stripped; `nil` when HEAD is detached.
    public let branch: String?
    public let sizeBytes: Int64
    public let state: State
    /// Sessions that ran in it, and the most recent one's last activity.
    public let sessionCount: Int
    public let lastActive: Date?

    public var id: URL { url }
    public var isLeftover: Bool { if case .leftover = state { true } else { false } }
    public var hasWork: Bool { if case .hasWork = state { true } else { false } }
}

/// One repository or project folder: its agent worktrees and the build output found in it.
public struct LeftoverGroup: Identifiable, Hashable, Sendable {
    /// The main checkout, or the project folder when it is not a git repository.
    public let root: URL
    public let worktrees: [AgentWorktree]
    public let buildOutputs: [BuildOutput]

    public var id: URL { root }
    public var name: String { root.lastPathComponent }

    /// What the guided action can free: leftover worktrees and build output not in use.
    public var reclaimableBytes: Int64 {
        worktrees.filter(\.isLeftover).reduce(0) { $0 + $1.sizeBytes }
            + buildOutputs.filter(\.isRemovable).reduce(0) { $0 + $1.sizeBytes }
    }

    /// Worktrees with work only they hold.
    public var worktreesWithWork: [AgentWorktree] { worktrees.filter(\.hasWork) }
}

public struct LeftoverReport: Hashable, Sendable {
    public let groups: [LeftoverGroup]

    public init(groups: [LeftoverGroup]) {
        self.groups = groups
    }

    public static let empty = LeftoverReport(groups: [])

    public var isEmpty: Bool { groups.isEmpty }
    public var reclaimableBytes: Int64 { groups.reduce(0) { $0 + $1.reclaimableBytes } }
    public var worktrees: [AgentWorktree] { groups.flatMap(\.worktrees) }
    public var buildOutputs: [BuildOutput] { groups.flatMap(\.buildOutputs) }

    /// What "Review…" selects: every leftover worktree and the build output inside agent
    /// worktrees. Build output in a main checkout is offered too, but left unticked: the user
    /// would reinstall before working there again.
    public var defaultSelection: Set<URL> {
        Set(worktrees.filter(\.isLeftover).map(\.url) + buildOutputs.filter { $0.isRemovable && !$0.isInMainCheckout }.map(\.url))
    }

    /// Every item a plan may include.
    public var selectable: Set<URL> {
        Set(worktrees.filter { $0.isLeftover || $0.hasWork }.map(\.url) + buildOutputs.filter(\.isRemovable).map(\.url))
    }
}

/// A plan for leftover checkouts and build output, plus what it leaves alone and why.
public struct LeftoverPlan: Identifiable, Hashable, Sendable {
    public var plan: Plan
    public let excluded: [CleanupExclusion]
    /// Worktrees with work only they hold that the user asked to include.
    public let worktreesWithWork: [URL]

    public var id: UUID { plan.id }
    public var isBlocked: Bool { plan.liveCheck.isLive }
    public var canExecute: Bool { !isBlocked && !plan.isEmpty && !plan.needsAcknowledgement }
    /// Moves a worktree, which leaves a stale entry in git: "consequences", the red button.
    public var hasConsequences: Bool { plan.moves.contains { $0.note.hasPrefix(LeftoverScanner.worktreeNotePrefix) } }

    /// "Moves 3 folders (1.2 GB) to the Trash. You can undo this."
    public var summary: String {
        if isBlocked { return "Nothing will change yet. " + plan.liveCheck.reasons.joined(separator: " ") }
        guard !plan.moves.isEmpty else { return "Nothing selected to remove." }
        let n = plan.moves.count
        return "Moves \(n) \(n == 1 ? "folder" : "folders") (\(CleanupPlan.bytes(plan.totalBytes))) to \((plan.destination ?? .trash).displayName). You can undo this."
    }
}
