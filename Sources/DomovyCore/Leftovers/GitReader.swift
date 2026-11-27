import Foundation

/// Read-only git for leftover worktrees: `worktree list`, `status`, `rev-parse`, `symbolic-ref`,
/// `for-each-ref`, `check-ignore` and `ls-files`, always with optional locks off, so a repository
/// is never written to. Domovy does not run `git worktree remove` or `prune`: both delete for
/// good, and `remove` also deletes the files git ignores (an `.env`) without a copy.
public struct GitReader: Sendable {
    /// `nil` when no git is installed; every question then answers "unsure".
    public let git: URL?
    /// Added to the inherited environment. Tests pass `GIT_CONFIG_GLOBAL=/dev/null`.
    public let environment: [String: String]

    public init(git: URL? = GitReader.locate(), environment: [String: String] = [:]) {
        self.git = git
        self.environment = environment
    }

    /// A real git, never the `/usr/bin/git` shim alone: without the Command Line Tools the shim
    /// asks to install them, and a background scan must not do that.
    public static func locate(fileManager: FileManager = .default) -> URL? {
        var candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git"]
        if let developer = try? fileManager.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
            candidates.append(developer + "/usr/bin/git")
        }
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// One entry of `git worktree list --porcelain`.
    public struct WorktreeEntry: Hashable, Sendable {
        public let path: URL
        public let branch: String?
        public let isBare: Bool
        public let isLocked: Bool
        /// Git already knows the folder is gone.
        public let isPrunable: Bool
    }

    /// Every worktree of the repository `folder` belongs to; the main checkout comes first.
    public func worktrees(of folder: URL) -> [WorktreeEntry]? {
        guard let output = run(["worktree", "list", "--porcelain"], in: folder), output.ok else { return nil }
        return Self.parseWorktreeList(output.text)
    }

    static func parseWorktreeList(_ text: String) -> [WorktreeEntry] {
        var entries: [WorktreeEntry] = []
        for block in text.components(separatedBy: "\n\n") {
            var path: String?
            var branch: String?
            var bare = false, locked = false, prunable = false
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
                else if line.hasPrefix("branch ") { branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
                else if line == "bare" { bare = true }
                else if line == "locked" || line.hasPrefix("locked ") { locked = true }
                else if line == "prunable" || line.hasPrefix("prunable ") { prunable = true }
            }
            guard let path else { continue }
            entries.append(WorktreeEntry(path: URL(fileURLWithPath: path, isDirectory: true), branch: branch, isBare: bare, isLocked: locked, isPrunable: prunable))
        }
        return entries
    }

    /// The top of the checkout `folder` is in; `nil` outside a repository.
    public func topLevel(of folder: URL) -> URL? {
        guard let output = run(["rev-parse", "--show-toplevel"], in: folder), output.ok, !output.trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: output.trimmed, isDirectory: true)
    }

    /// What a read-only look at a linked worktree found.
    public struct Inspection: Hashable, Sendable {
        /// Changed, staged or untracked paths (not ignored ones).
        public var changes: [String] = []
        /// Ignored paths that are not build output, such as `.env`: no commit keeps them.
        public var ignoredKept: [String] = []
        public var branch: String?
        /// A trunk branch that contains HEAD.
        public var mergedInto: String?
        /// HEAD is on a branch, or some branch or remote contains it.
        public var commitsOnABranch = false
    }

    /// `nil` when git could not read the worktree (its main repository may be gone).
    public func inspect(_ worktree: URL) -> Inspection? {
        guard let status = run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching"], in: worktree), status.ok,
              let head = run(["rev-parse", "--verify", "--quiet", "HEAD"], in: worktree), head.ok else { return nil }
        var result = Inspection()
        var tokens = status.text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let token = tokens.popFirst() {
            guard token.count > 3 else { continue }
            let code = token.prefix(2)
            let path = String(token.dropFirst(3))
            if code.first == "R" || code.first == "C" { _ = tokens.popFirst() } // the old name follows
            if code == "!!" {
                if !Self.isRebuildable(path) { result.ignoredKept.append(path) }
            } else {
                result.changes.append(path)
            }
        }
        result.branch = run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: worktree).flatMap { $0.ok && !$0.trimmed.isEmpty ? $0.trimmed : nil }
        let refs = run(["for-each-ref", "--contains", head.trimmed, "--format=%(refname)", "refs/heads", "refs/remotes"], in: worktree)
        let names = (refs?.ok == true ? refs?.text ?? "" : "").split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/HEAD") }
        result.commitsOnABranch = result.branch != nil || !names.isEmpty
        let own = result.branch.map { "refs/heads/" + $0 }
        let trunk = ["refs/heads/main", "refs/heads/master", "refs/remotes/origin/main", "refs/remotes/origin/master"]
        result.mergedInto = trunk.first { names.contains($0) && $0 != own }
            .map { $0.replacingOccurrences(of: "refs/heads/", with: "").replacingOccurrences(of: "refs/remotes/", with: "") }
        return result
    }

    /// An ignored path git reported that a build or install recreates.
    static func isRebuildable(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        let names = Set(BuildOutputKind.allCases.map(\.folderName))
        if components.contains(where: names.contains) { return true }
        guard let last = components.last else { return false }
        return last == ".DS_Store" || last.hasSuffix(".pyc")
    }

    /// Git ignores `folder` and tracks nothing in it: it is no part of the project's sources.
    public func isIgnoredAndUntracked(_ folder: URL, in checkout: URL) -> Bool {
        guard let relative = FileSystem.relativePath(of: folder, under: checkout), !relative.isEmpty else { return false }
        guard let ignored = run(["check-ignore", "--quiet", "--", relative], in: checkout), ignored.ok else { return false }
        guard let tracked = run(["ls-files", "-z", "--", relative], in: checkout), tracked.ok else { return false }
        return tracked.text.isEmpty
    }

    // MARK: Running

    struct Output {
        let ok: Bool
        let text: String
        var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func run(_ arguments: [String], in folder: URL) -> Output? {
        guard let git else { return nil }
        let process = Process()
        process.executableURL = git
        process.arguments = ["--no-optional-locks", "-C", folder.path] + arguments
        var environment = ProcessInfo.processInfo.environment.merging(self.environment) { _, new in new }
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
        return Output(ok: process.terminationStatus == 0, text: String(decoding: data, as: UTF8.self))
    }
}
