import Foundation

/// Disk use of Cursor: `~/Library/Application Support/Cursor` and `~/.cursor`.
/// Read-only in v0.1: the chats database is measured by its file size and never opened.
public struct CursorFootprint: FootprintProvider {
    public let kind: AgentKind = .cursor
    /// `Application Support/Cursor`.
    public let supportDirectory: URL
    /// `~/.cursor`.
    public let dotDirectory: URL

    public init(supportDirectory: URL, dotDirectory: URL) {
        self.supportDirectory = supportDirectory.standardizedFileURL
        self.dotDirectory = dotDirectory.standardizedFileURL
    }

    public init(home: URL) {
        self.init(
            supportDirectory: home.appendingPathComponent("Library/Application Support/Cursor", isDirectory: true),
            dotDirectory: home.appendingPathComponent(".cursor", isDirectory: true)
        )
    }

    /// The global chats database, `User/globalStorage/state.vscdb`.
    public var chatsDatabase: URL {
        supportDirectory.appendingPathComponent("User/globalStorage/state.vscdb")
    }

    /// Cursor's own cleanup, in its order. Raw SQL on chats deletes them all, so Domovy guides instead.
    public static let chatCleanupSteps = "In Cursor, run Developer: Delete Old Chats, then GC Agent KV Blobs, then quit Cursor."

    public func footprint() async throws -> Footprint {
        let hasSupport = FileSystem.isDirectory(supportDirectory)
        let hasDot = FileSystem.isDirectory(dotDirectory)
        guard hasSupport || hasDot else { throw AdapterError.notInstalled(kind) }
        var builder = FootprintBuilder(agent: kind, root: hasSupport ? supportDirectory : dotDirectory)

        let storage = chatsDatabase.deletingLastPathComponent()
        let database = FileSystem.children(of: storage).filter { $0.lastPathComponent.hasPrefix("state.vscdb") }
        builder.add("Chats database", database, reveal: storage, .consequences,
                    "Every Cursor chat lives in state.vscdb. Domovy never edits it.",
                    guidance: .instructions(Self.chatCleanupSteps))
        builder.add("CLI chats", dotDirectory.appendingPathComponent("chats", isDirectory: true), .consequences,
                    "Chats from the Cursor agent CLI. Delete them with cursor agent ls in Terminal.")
        builder.add("App data", appData(builder), reveal: supportDirectory, .keep,
                    "Settings, extensions state and caches Cursor needs.")
        builder.add("Extensions and projects", builder.unclaimedChildren(of: dotDirectory), reveal: dotDirectory, .keep,
                    "Extensions, worktrees and project state in ~/.cursor. Left alone.")
        return builder.build()
    }

    /// Everything in Application Support/Cursor except the chats database files.
    private func appData(_ builder: FootprintBuilder) -> [URL] {
        let storage = chatsDatabase.deletingLastPathComponent()
        var parts: [URL] = []
        // Walk down to globalStorage so the database is not counted twice.
        var level = supportDirectory
        for name in ["User", "globalStorage"] {
            let next = level.appendingPathComponent(name, isDirectory: true)
            parts += builder.unclaimedChildren(of: level).filter { $0.lastPathComponent != name }
            level = next
        }
        parts += builder.unclaimedChildren(of: storage)
        return parts
    }
}
