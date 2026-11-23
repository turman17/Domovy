import Foundation

extension CodexAdapter {
    /// Rollouts above this logical size are called out on their own.
    public static let largeRolloutBytes: Int64 = 100_000_000

    /// Read-only breakdown of `~/.codex`. Sizes come from file metadata; nothing is opened.
    public func footprint() async throws -> Footprint {
        guard FileSystem.exists(root) else { throw AdapterError.notInstalled(kind) }
        var builder = FootprintBuilder(agent: kind, root: root)

        let protected = CodexLayout.protectedRootEntries.sorted().map { root.appendingPathComponent($0) }
        builder.add("Settings, auth, rules, skills, plugins", protected, reveal: root, .keep,
                    "Codex needs these to run. Domovy never removes them.")

        let files = layout.rolloutFiles()
        let large = (files.active + files.archived).filter { DiskUsage.measure($0).logical > Self.largeRolloutBytes }
        builder.add("Large rollouts", large, reveal: layout.sessions, .consequences,
                    "\(large.count) \(large.count == 1 ? "rollout" : "rollouts") over 100 MB. Compress them in place, or archive or delete them in Sessions.",
                    guidance: .cleanup(.codexLargeRollouts))

        let threads = Set(files.active.compactMap { CodexLayout.rolloutName($0.lastPathComponent)?.threadID })
        builder.add("Session rollouts", sessionFiles(excluding: builder), reveal: layout.sessions, .consequences,
                    "\(threads.count) \(threads.count == 1 ? "session" : "sessions"). Delete or archive them one by one in Sessions.",
                    guidance: .manageInSessions)
        builder.add("Archived sessions", builder.unclaimedChildren(of: layout.archivedSessions), reveal: layout.archivedSessions,
                    .consequences, "Sessions archived in Codex; they can be unarchived.", guidance: .manageInSessions)
        builder.claim([layout.sessions, layout.archivedSessions])

        let children = FileSystem.children(of: root)
        builder.add("Logs database", layout.logsDatabaseFiles(), reveal: root, .safe,
                    "Diagnostic logs. Codex starts a fresh one; remove it only while Codex is quit.", guidance: .cleanup(.codexLogs))
        let databases = children.filter { $0.lastPathComponent.contains(".sqlite") } + [root.appendingPathComponent("sqlite")]
        builder.add("Thread databases", databases, reveal: root, .keep,
                    "Codex's thread list and history. Domovy only reads them.")
        builder.add("Worktrees", layout.worktrees, .consequences, "Git worktrees Codex created. They may hold uncommitted work.",
                    guidance: .cleanup(.codexWorktrees))
        builder.add("Generated images", layout.generatedImages, .consequences, "Images created in sessions. They go with their session.")
        builder.add("Attachments", layout.attachments, .consequences, "Pasted text and files attached to prompts.")
        builder.add("Prompt history", layout.history, .consequences, "Typed prompts for the prompt history picker.")
        builder.add("Other", builder.unclaimedChildren(of: root), reveal: root, .keep,
                    "Caches and state Domovy does not manage yet. Left alone.")
        return builder.build()
    }

    /// Every file below `sessions/` not already counted (the large rollouts).
    private func sessionFiles(excluding builder: FootprintBuilder) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: layout.sessions, includingPropertiesForKeys: [.isRegularFileKey], options: []) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }
            .map(\.standardizedFileURL)
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true && !builder.isClaimed($0) }
    }
}
