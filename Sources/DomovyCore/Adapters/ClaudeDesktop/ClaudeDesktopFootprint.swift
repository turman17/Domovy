import Foundation

/// Disk use of Claude Desktop (`~/Library/Application Support/Claude`). Measuring only;
/// its Claude Code sessions are listed through `ClaudeDesktopRegistry`.
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

    static let vmBundles = "vm_bundles"
    static let electronCaches = ["Cache", "Code Cache", "GraphiteDawnCache"]
    /// The VM row's note; the cleanup sheet repeats it word for word.
    public static let vmNote = "Removing it frees space; Cowork state is lost and the VM may download again."

    public func footprint() async throws -> Footprint {
        guard FileSystem.isDirectory(root) else { throw AdapterError.notInstalled(kind) }
        var builder = FootprintBuilder(agent: kind, root: root)
        func url(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }

        builder.add("VM bundle", url(Self.vmBundles), .consequences, Self.vmNote, guidance: .cleanup(.claudeDesktopVM))
        builder.add("Electron caches", Self.electronCaches.map(url), reveal: root, .safe,
                    "Cache, Code Cache, GraphiteDawnCache. Rebuilt on next launch.", guidance: .cleanup(.claudeDesktopCaches))
        builder.add("Cowork sessions", url("local-agent-mode-sessions"), .consequences,
                    "Cowork history and scheduled tasks. They are gone for good once removed.")
        builder.add("Session registry", url("claude-code-sessions"), .keep,
                    "Desktop's list of Claude Code sessions. Domovy changes it only while Claude Desktop is quit.")
        builder.add("Other", builder.unclaimedChildren(of: root), reveal: root, .keep,
                    "Settings, sign-in and app state Claude Desktop needs.")
        return builder.build()
    }
}
