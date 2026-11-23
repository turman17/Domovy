import Foundation

/// What a read-only look at one agent worktree found.
public enum WorktreeVerdict: Hashable, Sendable {
    /// Clean, and every commit is on another branch: nothing is lost by removing the folder.
    case removable(String)
    /// Kept, with the reason.
    case keep(String)
}

/// Read-only checks of a linked git worktree. Runs only `status`, `rev-parse`, `symbolic-ref`
/// and `for-each-ref`, with optional locks off, so the repository is never written to.
/// Domovy never runs `git worktree remove` or `prune`.
public struct GitWorktreeInspector: Sendable {
    public let git: URL

    public init(git: URL = URL(fileURLWithPath: "/usr/bin/git")) {
        self.git = git
    }

    /// A linked worktree has a `.git` file ("gitdir: ...") instead of a `.git` folder.
    public static func isLinkedWorktree(_ folder: URL) -> Bool {
        let dotGit = folder.appendingPathComponent(".git")
        guard !FileSystem.isDirectory(dotGit), let handle = try? FileHandle(forReadingFrom: dotGit) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8)) ?? Data()
        return head == Data("gitdir: ".utf8)
    }

    public func inspect(_ worktree: URL) -> WorktreeVerdict {
        guard Self.isLinkedWorktree(worktree) else {
            return .keep("Not a linked git worktree, so it may hold the only copy of a repository.")
        }
        guard FileManager.default.isExecutableFile(atPath: git.path) else {
            return .keep("git was not found, so Domovy cannot tell whether it holds uncommitted work.")
        }
        guard let status = run(["status", "--porcelain=v1", "--untracked-files=all", "--ignored"], in: worktree), status.ok else {
            return .keep("git could not read it (is its main repository gone?). Kept in case it holds the only copy of some work.")
        }
        let lines = status.output.split(separator: "\n")
        let ignored = lines.filter { $0.hasPrefix("!! ") }.count
        let changes = lines.count - ignored
        if changes > 0 {
            return .keep("Has uncommitted changes (\(changes) \(changes == 1 ? "file" : "files")).")
        }
        // Ignored files (`.env`, a local database, build output) are in no commit: removing the
        // folder would lose them.
        if ignored > 0 {
            return .keep("Holds \(ignored) \(ignored == 1 ? "item" : "items") git ignores (such as .env or build output), which no commit keeps.")
        }
        guard let head = run(["rev-parse", "--verify", "--quiet", "HEAD"], in: worktree), head.ok else {
            return .keep("Has no commits yet.")
        }
        let own = run(["symbolic-ref", "--quiet", "HEAD"], in: worktree).flatMap { $0.ok ? $0.trimmed : nil }
        guard let refs = run(["for-each-ref", "--contains", head.trimmed, "--format=%(refname)", "refs/heads", "refs/remotes"], in: worktree), refs.ok else {
            return .keep("git could not list the branches that contain its commits.")
        }
        let elsewhere = refs.output.split(separator: "\n").map(String.init).filter { $0 != own && !$0.hasSuffix("/HEAD") }
        // Name the trunk when it is one of them; it is what the user recognises.
        let trunk = ["refs/heads/main", "refs/heads/master", "refs/remotes/origin/main", "refs/remotes/origin/master"]
        guard let first = trunk.first(where: elsewhere.contains) ?? elsewhere.first else {
            return .keep("Has commits that are on no other branch.")
        }
        let name = first.replacingOccurrences(of: "refs/heads/", with: "").replacingOccurrences(of: "refs/remotes/", with: "")
        return .removable("Clean; its commits are on \(name).")
    }

    private struct Output {
        let ok: Bool
        let output: String
        var trimmed: String { output.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func run(_ arguments: [String], in folder: URL) -> Output? {
        let process = Process()
        process.executableURL = git
        process.arguments = ["--no-optional-locks", "-C", folder.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(ok: process.terminationStatus == 0, output: String(decoding: data, as: UTF8.self))
    }
}
