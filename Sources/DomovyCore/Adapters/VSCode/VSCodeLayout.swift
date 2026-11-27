import Foundation

/// One VS Code build on this Mac: VS Code, VS Code Insiders or VSCodium. All three keep their
/// data in `~/Library/Application Support/<folder>/User` with the same layout (verified for
/// VS Code 1.138; Insiders and VSCodium share the workbench code, not verified on a real install).
struct VSCodeFlavor: Sendable, Hashable {
    /// Shown to the user.
    let name: String
    /// `Application Support/<folder>`.
    let folder: String
    /// The app's main process and its Electron helpers (`Code`, `Code Helper (Renderer)`).
    let matcher: ProcessMatcher

    static let all: [VSCodeFlavor] = [
        VSCodeFlavor(name: "VS Code", folder: "Code", matcher: ProcessMatcher(
            appName: "VS Code", names: [], prefixes: ["code helper"], exactNames: ["Code"],
            quitAdvice: "Quit VS Code completely (Code \u{203A} Quit Visual Studio Code) first.")),
        VSCodeFlavor(name: "VS Code Insiders", folder: "Code - Insiders", matcher: ProcessMatcher(
            appName: "VS Code Insiders", names: [], prefixes: ["code - insiders helper"], exactNames: ["Code - Insiders"],
            quitAdvice: "Quit VS Code Insiders completely first.")),
        VSCodeFlavor(name: "VSCodium", folder: "VSCodium", matcher: ProcessMatcher(
            appName: "VSCodium", names: ["vscodium"], prefixes: ["vscodium helper"],
            quitAdvice: "Quit VSCodium completely first.")),
    ]
}

/// Paths inside one flavor's `User` folder, from VS Code's `ChatSessionStore`
/// (src/vs/workbench/contrib/chat/common/model/chatSessionStore.ts, lines 37-76 and 738-740):
/// a workspace window's chats are `workspaceStorage/<workspace id>/chatSessions/<sessionId>.json`
/// and `.jsonl`, listed in the key `chat.ChatSessionStore.index` of that workspace's
/// `state.vscdb`; an empty window's go to `globalStorage/emptyWindowChatSessions/`, listed in the
/// global `state.vscdb`. Edit state is `workspaceStorage/<id>/chatEditingSessions/<sessionId>/`.
struct VSCodeLayout: Sendable {
    let flavor: VSCodeFlavor
    /// `Application Support/<folder>`.
    let support: URL

    var user: URL { support.appendingPathComponent("User", isDirectory: true) }
    var globalStorage: URL { user.appendingPathComponent("globalStorage", isDirectory: true) }
    var globalDatabase: URL { globalStorage.appendingPathComponent("state.vscdb") }
    var workspaceStorage: URL { user.appendingPathComponent("workspaceStorage", isDirectory: true) }

    static let indexKey = "chat.ChatSessionStore.index"

    static func layouts(home: URL) -> [VSCodeLayout] {
        VSCodeFlavor.all.map { VSCodeLayout(flavor: $0, support: home.appendingPathComponent("Library/Application Support/\($0.folder)", isDirectory: true)) }
    }

    var isPresent: Bool { FileSystem.isDirectory(user) }

    /// One place chats are kept: a folder of session files, the database that lists them, and
    /// the folder of their edit state.
    struct Store: Sendable, Hashable {
        let sessions: URL
        /// `nil` for the old `no-workspace` folder, which no index lists.
        let database: URL?
        let editing: URL?
        /// The workspace folder the window had open, from `workspace.json`.
        let project: String?
    }

    func stores() -> [Store] {
        var result: [Store] = []
        for folder in FileSystem.children(of: workspaceStorage) where FileSystem.isDirectory(folder) {
            guard SafeID.isSafe(folder.lastPathComponent) else { continue }
            if folder.lastPathComponent == "no-workspace" {
                result.append(Store(sessions: folder.appendingPathComponent("chatSessions", isDirectory: true), database: nil, editing: nil, project: nil))
                continue
            }
            result.append(Store(sessions: folder.appendingPathComponent("chatSessions", isDirectory: true),
                                database: folder.appendingPathComponent("state.vscdb"),
                                editing: folder.appendingPathComponent("chatEditingSessions", isDirectory: true),
                                project: Self.project(of: folder)))
        }
        result.append(Store(sessions: globalStorage.appendingPathComponent("emptyWindowChatSessions", isDirectory: true),
                            database: globalDatabase, editing: nil, project: nil))
        return result
    }

    /// `workspace.json`: `{"folder": "file:///…"}` or `{"workspace": "file:///….code-workspace"}`.
    static func project(of workspace: URL) -> String? {
        guard let data = try? Data(contentsOf: workspace.appendingPathComponent("workspace.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = (object["folder"] ?? object["workspace"]) as? String,
              let url = URL(string: text), url.isFileURL else { return nil }
        return url.path
    }
}

/// Reads one JSON value of a `state.vscdb` `ItemTable`, read-only.
enum VSCodeState {
    /// `ItemTable (key TEXT UNIQUE, value BLOB)`, as in every VS Code `state.vscdb`.
    static func hasItemTable(_ database: URL) -> Bool {
        guard let reader = SQLiteReader(url: database) else { return false }
        return reader.columns(of: "ItemTable").isSuperset(of: ["key", "value"])
    }

    static func value(_ key: String, in database: URL) -> Data? {
        guard FileSystem.exists(database), let reader = SQLiteReader(url: database),
              let text = reader.rows("SELECT CAST(value AS TEXT) FROM ItemTable WHERE key = ?1", [key]).first?.first ?? nil else { return nil }
        return Data(text.utf8)
    }
}
