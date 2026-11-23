import Foundation

extension ClaudeCodeAdapter {
    /// Companions this recent are left out of "orphaned": they may belong to a session that
    /// has just started and not written its transcript yet.
    static let orphanGracePeriod: TimeInterval = 3_600

    /// Read-only breakdown of `~/.claude`. Sizes come from file metadata; nothing is opened.
    public func footprint() async throws -> Footprint {
        guard FileSystem.exists(root) else { throw AdapterError.notInstalled(kind) }
        var builder = FootprintBuilder(agent: kind, root: root)

        // Everything the agent needs, first, so no other row can count it.
        let slugs = FileSystem.children(of: layout.projects).filter(FileSystem.isDirectory)
        let memory = slugs.flatMap { slug in
            ClaudeCodeLayout.protectedProjectEntries.map { slug.appendingPathComponent($0, isDirectory: true) }
        }
        let protected = ClaudeCodeLayout.protectedRootEntries.sorted().map { root.appendingPathComponent($0) }
        builder.add("Settings, plugins, skills, memory", protected + memory, reveal: root, .keep,
                    "Claude Code needs these to run. Domovy never removes them.")

        let orphans = orphanedCompanions(slugs: slugs)
        builder.add("Orphaned companions", orphans, reveal: root, .safe,
                    "\(orphans.count) \(orphans.count == 1 ? "folder" : "folders") whose transcript is already gone.")

        let transcripts = slugs.flatMap { builder.unclaimedChildren(of: $0) }
        let count = transcripts.filter { ClaudeCodeLayout.sessionID(ofTranscriptNamed: $0.lastPathComponent) != nil }.count
        builder.add("Session transcripts", transcripts, reveal: layout.projects, .consequences,
                    "\(count) \(count == 1 ? "session" : "sessions"). Delete or archive them one by one in Sessions.",
                    guidance: .manageInSessions)
        builder.claim(slugs + [layout.projects])

        let venv = layout.security.appendingPathComponent("agent-sdk-venv", isDirectory: true)
        builder.add("Agent SDK environment", venv, .safe, "security/agent-sdk-venv. Claude Code reinstalls it when needed.")

        func rest(of folder: URL) -> [URL] { builder.unclaimedChildren(of: folder) }
        builder.add("Checkpoints", rest(of: layout.fileHistory), reveal: layout.fileHistory, .consequences,
                    "File snapshots for /rewind. They go with their session.")
        builder.add("Uploads", rest(of: layout.uploads), reveal: layout.uploads, .consequences, "Files attached to sessions.")
        builder.add("Dev mods", rest(of: layout.devMods), reveal: layout.devMods, .consequences, "Per-session development modifications.")
        builder.add("Security state", rest(of: layout.security), reveal: layout.security, .consequences, "Security warning state per session.")
        builder.add("Session environments", rest(of: layout.sessionEnv), reveal: layout.sessionEnv, .safe,
                    "Environment metadata per session; Claude Code sweeps it itself.")
        builder.claim([layout.fileHistory, layout.uploads, layout.devMods, layout.security, layout.sessionEnv])

        builder.add("Prompt history", layout.history, .consequences, "Typed prompts for the prompt history picker.")
        builder.add("Paste cache", root.appendingPathComponent("paste-cache"), .safe, "Cached pastes; Claude Code sweeps them by age.")
        builder.add("Shell snapshots", root.appendingPathComponent("shell-snapshots"), .safe, "Left behind after crashes; swept by age.")
        builder.add("Backups", root.appendingPathComponent("backups"), .safe, "Copies of ~/.claude.json; Claude Code keeps the newest five.")
        builder.add("Other", builder.unclaimedChildren(of: root), reveal: root, .keep,
                    "Caches and state Domovy does not manage yet. Left alone.")
        return builder.build()
    }

    /// Uuid-keyed folders (and session-env files) whose transcript no longer exists anywhere.
    /// Names and modification dates only; nothing is opened.
    func orphanedCompanions(slugs: [URL]) -> [URL] {
        var known = Set<String>()
        var candidates: [URL] = []
        for slug in slugs {
            for entry in FileSystem.children(of: slug) {
                let name = entry.lastPathComponent
                if let id = ClaudeCodeLayout.sessionID(ofTranscriptNamed: name) ?? ClaudeCodeLayout.sessionID(ofSetAsideCopyNamed: name) {
                    known.insert(id)
                } else if ClaudeCodeLayout.isUUID(name), FileSystem.isDirectory(entry) {
                    candidates.append(entry)
                }
            }
        }
        for folder in [layout.fileHistory, layout.uploads, layout.devMods, layout.sessionEnv] {
            candidates += FileSystem.children(of: folder).filter { ClaudeCodeLayout.isUUID($0.lastPathComponent) }
        }
        let cutoff = now().addingTimeInterval(-Self.orphanGracePeriod)
        return candidates.filter { url in
            !known.contains(url.lastPathComponent.lowercased())
                && !layout.isProtected(url)
                && (FileSystem.modificationDate(of: url) ?? .distantFuture) < cutoff
        }
    }
}
