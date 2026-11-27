import Foundation

/// Kiro CLI and the Kiro IDE. Closed source, and the sources disagree (docs/research/agent_storage_formats.md, Q9):
/// - Kiro's docs say sessions are "SQLite in ~/.kiro/", per folder, with `kiro-cli chat --list-sessions`
///   and `kiro-cli chat --delete-session <ID>` (permanent; refuses a session open elsewhere)
///   (https://kiro.dev/docs/cli/chat/session-management/).
/// - A third-party reader describes CLI 3.0 as `~/.kiro/sessions/<workspace hash>/sess_<id>/` with
///   `session.json` (`title`, `workspacePaths`), `messages.jsonl` and `snapshots/`; CLI 2.x as
///   `~/.kiro/sessions/cli/<id>.jsonl` plus `<id>.json`; and CLI 2.x TUI and 1.x as
///   `~/Library/Application Support/kiro-cli/data.sqlite3` (https://pypi.org/project/kiro-cli-history/).
/// - The IDE keeps chats in `~/Library/Application Support/Kiro/User/globalStorage/kiro.kiroagent/`,
///   whose format changed in early 2026 (https://github.com/kirodotdev/Kiro/issues/5469).
/// None of these could be sourced precisely, so Domovy lists the CLI 3.0 and 2.x folders it can
/// read, measures the rest and never changes anything; Kiro's own delete is not run either,
/// because Domovy could not keep a copy of what a permanent delete removes.
struct KiroLayout: Sendable {
    let home: URL

    var dot: URL { home.appendingPathComponent(".kiro", isDirectory: true) }
    var sessions: URL { dot.appendingPathComponent("sessions", isDirectory: true) }
    var classic: URL { sessions.appendingPathComponent("cli", isDirectory: true) }
    var cliSupport: URL { home.appendingPathComponent("Library/Application Support/kiro-cli", isDirectory: true) }
    var ide: URL { home.appendingPathComponent("Library/Application Support/Kiro", isDirectory: true) }
    var ideAgent: URL { ide.appendingPathComponent("User/globalStorage/kiro.kiroagent", isDirectory: true) }

    var isInstalled: Bool { [dot, cliSupport, ide].contains(where: FileSystem.isDirectory) }

    struct Entry: Sendable {
        let id: String
        let file: URL
        let title: String?
        let project: String?
        /// Files of this session, for size and open-file checks.
        let items: [URL]
    }

    /// CLI 3.0 `sess_<id>/session.json` and CLI 2.x `cli/<id>.jsonl` (+ `<id>.json`).
    func entries() -> [Entry] {
        var result: [Entry] = []
        for workspace in FileSystem.children(of: sessions) where FileSystem.isDirectory(workspace) && workspace != classic {
            for folder in FileSystem.children(of: workspace) where folder.lastPathComponent.hasPrefix("sess_") && FileSystem.isDirectory(folder) {
                let meta = folder.appendingPathComponent("session.json")
                guard let object = FileSessions.object(meta) else { continue }
                let paths = object["workspacePaths"] as? [String]
                result.append(Entry(id: String(folder.lastPathComponent.dropFirst(5)), file: meta, title: FileSessions.title(object["title"] as? String),
                                    project: paths?.first { $0.hasPrefix("/") }, items: [folder]))
            }
        }
        for file in FileSystem.children(of: classic) where file.pathExtension == "jsonl" {
            let id = file.deletingPathExtension().lastPathComponent
            let meta = classic.appendingPathComponent("\(id).json")
            let object = FileSessions.object(meta) ?? [:]
            result.append(Entry(id: id, file: file, title: FileSessions.title(object["title"] as? String),
                                project: (object["cwd"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil },
                                items: [file, meta].filter { FileSystem.exists($0) }))
        }
        return result
    }
}

/// Kiro, read-only. Lists the CLI sessions Domovy can read and measures the CLI and the IDE.
public struct KiroAdapter: AgentAdapter {
    public let kind: AgentKind = .kiro
    public let root: URL

    let layout: KiroLayout
    let openHandles: any OpenHandleChecker

    public static let readOnlyReason = "Kiro's docs and third-party readers disagree on where Kiro keeps sessions, so Domovy only lists what it can read and changes nothing. Delete a session with `kiro-cli chat --delete-session <id>` or /sessions in Kiro."

    public init(home: URL, openHandles: any OpenHandleChecker = LibprocOpenHandleChecker.shared) {
        self.layout = KiroLayout(home: home.standardizedFileURL)
        self.root = layout.dot
        self.openHandles = openHandles
    }

    public var scope: [URL] { [layout.dot, layout.cliSupport, layout.ide] }

    public func status() async -> AdapterStatus {
        layout.isInstalled ? .readOnly(reason: Self.readOnlyReason) : .notInstalled
    }

    public func sessions() async throws -> [Session] {
        guard layout.isInstalled else { throw AdapterError.notInstalled(kind) }
        let entries = layout.entries()
        let holders = await openHandleHolders(of: entries.map(\.items), checker: openHandles)
        return zip(entries, holders).map { entry, holders in
            let live = FileSessions.liveness(markers: [], holders: holders, signals: [])
            return Session(id: entry.id, agent: kind, title: entry.title, projectPath: entry.project,
                           lastActive: entry.items.compactMap(FileSystem.modificationDate).max() ?? .distantPast,
                           sizeBytes: entry.items.reduce(0) { $0 + FileSystem.size(of: $1) },
                           status: live.isLive ? .live : .idle, expiresAt: nil, transcriptURL: entry.file)
        }
        .sorted { $0.lastActive > $1.lastActive }
    }

    public func artifacts(of session: Session) async throws -> [Artifact] {
        try locate(session).items.map { Artifact(url: $0, kind: FileSystem.isDirectory($0) ? .folder : .file, sizeBytes: FileSystem.size(of: $0), note: "Session data") }
    }

    public func liveCheck(_ session: Session) async throws -> LiveCheckResult {
        FileSessions.liveness(markers: [], holders: await openHandles.holders(of: try locate(session).items), signals: [])
    }

    public func deletePlan(for session: Session, destination: Destination = .trash) async throws -> Plan {
        throw AdapterError.readOnly(kind, reason: Self.readOnlyReason)
    }

    public func archivePlan(for session: Session) async throws -> Plan {
        throw AdapterError.readOnly(kind, reason: Self.readOnlyReason)
    }

    /// The message format is undocumented; Domovy does not guess at it.
    public func transcript(of session: Session, limit: Int, masking findings: [SecretFinding]) async throws -> Transcript { .empty }

    private func locate(_ session: Session) throws -> KiroLayout.Entry {
        guard session.agent == kind, let entry = layout.entries().first(where: { $0.id == session.id && $0.file == session.transcriptURL.standardizedFileURL }) else {
            throw AdapterError.sessionNotFound(session.id)
        }
        return entry
    }
}

extension KiroAdapter {
    public func footprint() async throws -> Footprint {
        guard layout.isInstalled else { throw AdapterError.notInstalled(kind) }
        var builder = FootprintBuilder(agent: kind, root: root)
        let advice = "In Kiro CLI: kiro-cli chat --list-sessions, then kiro-cli chat --delete-session <id>; /sessions clean removes empty ones."
        builder.add("CLI sessions", layout.sessions, .consequences, "Kiro CLI's sessions. Domovy lists them but leaves deleting to Kiro.", advice: advice)
        builder.add("CLI database (older versions)", SharedDatabaseLiveness.files(of: layout.cliSupport.appendingPathComponent("data.sqlite3")), reveal: layout.cliSupport, .keep,
                    "Kiro CLI 1.x and 2.x kept sessions and sign-in in this database. Domovy never changes it.")
        builder.add("IDE chats", layout.ideAgent, .consequences,
                    "Kiro IDE's agent chats and execution logs. Their format is undocumented, so Domovy only measures them; clear old chats in Kiro.")
        builder.add("Settings", builder.unclaimedChildren(of: layout.dot), reveal: layout.dot, .keep, "Kiro's settings, steering, agents and MCP config. Left alone.")
        builder.add("CLI state", builder.unclaimedChildren(of: layout.cliSupport), reveal: layout.cliSupport, .keep, "Kiro CLI's state and logs. Left alone.")
        return builder.build()
    }
}
