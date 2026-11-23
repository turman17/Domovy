import Foundation

/// Disk use of Cursor: `~/Library/Application Support/Cursor` and `~/.cursor`. Measures files
/// only; `CursorAdapter` adds what its chats hold and links the chat rows to Sessions.
public struct CursorFootprint: FootprintProvider {
    /// What the adapter read from the chats database.
    public struct ChatSummary: Sendable {
        public let chats: Int
        /// Bytes of the chats' own rows (values), not the file.
        public let bytes: Int64
        public let cliChats: Int
    }

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

    /// Cursor's own cleanup, in its order. A raw DELETE and VACUUM on the chat tables deletes
    /// every chat, so Domovy never does that.
    public static let chatCleanupSteps = "In Cursor, run Developer: Delete Old Chats, then GC Agent KV Blobs, then quit Cursor."

    public func footprint() async throws -> Footprint {
        try await footprint(summary: nil)
    }

    /// With a summary the chat rows link to Sessions, where chats are deleted one by one.
    func footprint(summary: ChatSummary?) async throws -> Footprint {
        let hasSupport = FileSystem.isDirectory(supportDirectory)
        let hasDot = FileSystem.isDirectory(dotDirectory)
        guard hasSupport || hasDot else { throw AdapterError.notInstalled(kind) }
        var builder = FootprintBuilder(agent: kind, root: hasSupport ? supportDirectory : dotDirectory)

        let storage = chatsDatabase.deletingLastPathComponent()
        let database = FileSystem.children(of: storage).filter { $0.lastPathComponent.hasPrefix("state.vscdb") }
        if let summary {
            let n = summary.chats
            let bytes = ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file)
            builder.add("Chats database", database, reveal: storage, .consequences,
                        "\(n) \(n == 1 ? "chat" : "chats") (\(bytes) of rows) in state.vscdb. Delete them one by one in Sessions with Cursor quit; Domovy keeps a copy of the database for undo.",
                        guidance: .manageInSessions, advice: Self.chatCleanupSteps)
        } else {
            builder.add("Chats database", database, reveal: storage, .consequences,
                        "Every Cursor chat lives in state.vscdb.", guidance: .instructions(Self.chatCleanupSteps))
        }
        let cliNote = summary.map { "\($0.cliChats) \($0.cliChats == 1 ? "chat" : "chats") from the Cursor agent CLI. Delete or archive them in Sessions." }
        builder.add("CLI chats", dotDirectory.appendingPathComponent("chats", isDirectory: true), .consequences,
                    cliNote ?? "Chats from the Cursor agent CLI. Delete them with cursor agent ls in Terminal.",
                    guidance: summary == nil ? nil : .manageInSessions)
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
