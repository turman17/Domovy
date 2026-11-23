import Foundation

extension CopilotAdapter {
    /// Read-only breakdown of `~/.copilot`. Sizes come from file metadata; nothing is opened.
    public func footprint() async throws -> Footprint {
        guard FileSystem.isDirectory(root) else { throw AdapterError.notInstalled(kind) }
        var builder = FootprintBuilder(agent: kind, root: root)
        let store = ["session-store.db", "session-store.db-wal", "session-store.db-shm"].map { root.appendingPathComponent($0) }
        let settings = CopilotLayout.protectedEntries.subtracting(store.map(\.lastPathComponent)).sorted().map { root.appendingPathComponent($0) }
        builder.add("Settings, agents, skills", settings, reveal: root, .keep, "Copilot CLI needs these to run. Domovy never removes them.")

        let count = layout.sessionFolders().count
        builder.add("Sessions", layout.sessionState, .consequences,
                    "\(count) \(count == 1 ? "session" : "sessions"). Delete or archive them one by one in Sessions.", guidance: .manageInSessions)
        builder.add("Search index", store, reveal: root, .keep,
                    "Copilot CLI's index for search and /chronicle. Rebuilding it with /chronicle reindex also syncs your sessions to your GitHub account.")
        builder.add("Older session history", layout.legacyHistory, .consequences,
                    "Sessions saved by earlier Copilot CLI versions, one file each.")
        builder.add("Command history", layout.commandHistory, .consequences, "Commands you typed, for Copilot CLI's history.")
        builder.add("Logs", layout.logs, .safe, "One log per Copilot CLI run. It writes new ones; remove them while it is quit.")
        builder.add("Other", builder.unclaimedChildren(of: root), reveal: root, .keep,
                    "Caches and state Domovy does not manage yet. Left alone.")
        return builder.build()
    }
}
