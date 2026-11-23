import Foundation

/// Cleanups that move whole folders or files: the Claude Desktop VM bundle and caches, the
/// Agent SDK environment and the Codex logs database.
extension CleanupPlanner {
    func vmBundlePlan(destination: Destination) async throws -> CleanupPlan {
        let folder = desktopSupport.appendingPathComponent(ClaudeDesktopFootprint.vmBundles, isDirectory: true)
        // The contents move, the folder stays: Desktop finds the place it expects.
        let items = try requireExisting(FileSystem.children(of: folder), .claudeDesktopVM)
        let place = destination == .trash ? "while it is still in the Trash" : "while it is still in the Domovy quarantine folder"
        return await movePlan(
            .claudeDesktopVM,
            items: items.map { ($0, "Claude Desktop's Cowork VM") },
            matchers: [Self.desktopMatcher],
            remarks: [
                "\(ClaudeDesktopFootprint.vmNote) Domovy can put it back with Undo \(place).",
                "Not verified by Anthropic: whether Claude Desktop downloads the VM again after it is removed, and exactly what Cowork state goes with it.",
            ],
            hasConsequences: true,
            destination: destination
        )
    }

    func desktopCachesPlan(destination: Destination) async throws -> CleanupPlan {
        let urls = ClaudeDesktopFootprint.electronCaches.map { desktopSupport.appendingPathComponent($0, isDirectory: true) }
        let items = try requireExisting(urls, .claudeDesktopCaches)
        return await movePlan(
            .claudeDesktopCaches,
            items: items.map { ($0, "Electron cache; Claude Desktop rebuilds it on next launch") },
            matchers: [Self.desktopMatcher],
            remarks: ["These caches hold UI state only, no messages. Claude Desktop rebuilds them on next launch."],
            hasConsequences: false,
            destination: destination
        )
    }

    func agentSDKPlan(destination: Destination) async throws -> CleanupPlan {
        let venv = ClaudeCodeLayout(root: claudeCodeRoot).agentSDKEnvironment
        let items = try requireExisting([venv], .claudeCodeAgentSDK)
        return await movePlan(
            .claudeCodeAgentSDK,
            items: items.map { ($0, "Python environment for the Agent SDK; Claude Code reinstalls it when needed") },
            matchers: [],
            remarks: ["Claude Code reinstalls this environment the next time it needs it."],
            hasConsequences: false,
            destination: destination
        )
    }

    func codexLogsPlan(destination: Destination) async throws -> CleanupPlan {
        let items = try requireExisting(CodexLayout(root: codexRoot).logsDatabaseFiles(), .codexLogs)
        return await movePlan(
            .codexLogs,
            items: items.map { ($0, $0.lastPathComponent == "logs_2.sqlite" ? "Codex diagnostic logs" : "Belongs to the logs database; moves with it") },
            matchers: [codexMatcher],
            remarks: ["Diagnostic logs only. Codex starts a fresh database on next launch; the database and its -wal and -shm files move together."],
            hasConsequences: false,
            destination: destination
        )
    }
}
