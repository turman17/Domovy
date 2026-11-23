import Foundation

/// Disk use of Claude Desktop (`~/Library/Application Support/Claude`). Measuring only:
/// Desktop sessions are not listed yet, and nothing here changes a file.
public struct ClaudeDesktopFootprint: FootprintProvider {
    public let kind: AgentKind = .claudeDesktop
    public let root: URL

    /// - Parameter supportDirectory: the `Claude` folder in Application Support. Tests pass a fixture.
    public init(supportDirectory: URL) {
        self.root = supportDirectory.standardizedFileURL
    }

    /// Convenience for a home directory: `<home>/Library/Application Support/Claude`.
    public init(home: URL) {
        self.init(supportDirectory: home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true))
    }

    public func footprint() async throws -> Footprint {
        guard FileSystem.isDirectory(root) else { throw AdapterError.notInstalled(kind) }
        var builder = FootprintBuilder(agent: kind, root: root)
        func url(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }

        builder.add("VM bundle", url("vm_bundles"), .consequences,
                    "Removing it frees space; Cowork state is lost and the VM may download again.",
                    guidance: .instructions("Quit Claude Desktop before removing it."))
        builder.add("Electron caches", ["Cache", "Code Cache", "GraphiteDawnCache"].map(url), reveal: root, .safe,
                    "Cache, Code Cache, GraphiteDawnCache. Rebuilt on next launch.")
        builder.add("Cowork sessions", url("local-agent-mode-sessions"), .consequences,
                    "Cowork history and scheduled tasks. They are gone for good once removed.")
        builder.add("Session registry", url("claude-code-sessions"), .keep,
                    "Desktop's list of Claude Code sessions. Domovy only reads it.")
        builder.add("Other", builder.unclaimedChildren(of: root), reveal: root, .keep,
                    "Settings, sign-in and app state Claude Desktop needs.")
        return builder.build()
    }
}
