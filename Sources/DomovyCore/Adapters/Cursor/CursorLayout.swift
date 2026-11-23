import Foundation

/// Paths of Cursor's storage. Editor chats are rows of one SQLite key-value database,
/// `Application Support/Cursor/User/globalStorage/state.vscdb` (tables `ItemTable` and
/// `cursorDiskKV`, both `key TEXT UNIQUE, value BLOB`; verified on a real install). Chats of the
/// Cursor agent CLI are folders, `~/.cursor/chats/<workspace hash>/<chat id>/` (assumed).
struct CursorLayout: Sendable {
    /// `Application Support/Cursor`.
    let support: URL
    /// `~/.cursor`.
    let dot: URL

    var globalStorage: URL { support.appendingPathComponent("User/globalStorage", isDirectory: true) }
    var database: URL { globalStorage.appendingPathComponent("state.vscdb") }
    /// The database and its journal files: cloned before an edit, and nothing may hold them open.
    var databaseFiles: [URL] { ["", "-wal", "-shm"].map { globalStorage.appendingPathComponent("state.vscdb" + $0) } }
    /// An older copy Cursor no longer updates (Cursor staff); it still holds old chats.
    var backup: URL { globalStorage.appendingPathComponent("state.vscdb.backup") }
    var workspaceStorage: URL { support.appendingPathComponent("User/workspaceStorage", isDirectory: true) }
    var cliChats: URL { dot.appendingPathComponent("chats", isDirectory: true) }

    /// The tables Domovy reads and edits, as verified.
    static let tables = ["ItemTable", "cursorDiskKV"]
    /// Cursor 3.0+ keeps its chat list here, in `ItemTable` (reported, not verified here).
    static let headersKey = "composer.composerHeaders"
    /// Pre-3.0 workspace databases list their chats here (reported).
    static let workspaceListKey = "composer.composerData"

    /// The Cursor app: `Cursor` and its Electron helpers `Cursor Helper`, `Cursor Helper (GPU)`,
    /// `(Renderer)`, `(Plugin)` (names verified in Cursor's own process log). Case-sensitive
    /// `Cursor`, and a prefix with the space, so Apple's `CursorUIViewService` never matches.
    static let appMatcher = ProcessMatcher(
        appName: "Cursor", names: [], prefixes: ["cursor helper"], exactNames: ["Cursor"],
        quitAdvice: "Quit Cursor completely (Cursor \u{203A} Quit Cursor) to delete its chats."
    )

    /// The Cursor agent CLI (`cursor-agent`, assumed). Blocks only while it uses a chats folder.
    func cliMatcher() -> ProcessMatcher {
        ProcessMatcher(appName: "Cursor CLI", names: ["cursor-agent"], scope: cliChats,
                       quitAdvice: "Quit cursor-agent first.", argumentMarkers: ["cursor-agent"])
    }

    /// Whether `url` is one chat folder of the CLI, `chats/<hash>/<id>`, and nothing else.
    func isCLIChatFolder(_ url: URL) -> Bool {
        guard let relative = FileSystem.relativePath(of: url, under: cliChats) else { return false }
        let parts = relative.split(separator: "/")
        return parts.count == 2 && parts.allSatisfy { !$0.hasPrefix(".") }
    }

    func cliChatFolders() -> [URL] {
        FileSystem.children(of: cliChats).filter(FileSystem.isDirectory).flatMap { hash in
            FileSystem.children(of: hash).filter { FileSystem.isDirectory($0) && isCLIChatFolder($0) }
        }
    }

    // MARK: Probe

    /// What Domovy knows about the chats database.
    enum DatabaseState: Equatable {
        case absent
        case ready
        case unknown(String)
    }

    func probe() -> AdapterStatus {
        guard FileSystem.isDirectory(support) || FileSystem.isDirectory(dot) else { return .notInstalled }
        if case .unknown(let reason) = databaseState() { return .readOnly(reason: reason) }
        return .ready
    }

    func databaseState() -> DatabaseState {
        guard FileSystem.exists(database) else { return .absent }
        guard let reader = SQLiteReader(url: database) else {
            return .unknown("Domovy could not open Cursor's chat database (state.vscdb) read-only.")
        }
        for table in Self.tables where !reader.columns(of: table).isSuperset(of: ["key", "value"]) {
            return .unknown("Cursor's chat database has a layout Domovy does not know (no \(table) table with key and value), so it only shows what it can read.")
        }
        if case .unknown = CursorHeaders.load(reader) {
            return .unknown("Cursor's chat list (composer.composerHeaders) has a shape Domovy does not know, so it does not edit Cursor's chats.")
        }
        return .ready
    }
}
