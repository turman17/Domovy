import Foundation

/// Goose's storage, read from block/goose@059fee25 (docs/research/agent_storage_formats.md, Q9; not
/// verified on a real install). Permalink base:
/// https://github.com/block/goose/blob/059fee25f13fa92be561a7d42cdd04ececef5a98/
///
/// - Data goes to `etcetera`'s app strategy for `Block`/`goose` (crates/goose/src/config/paths.rs#L8-L38):
///   `~/.local/share/goose/` with the XDG strategy, while the docs and a code comment name
///   `~/Library/Application Support/Block/goose/`. Domovy checks both. `GOOSE_PATH_ROOT` is not followed.
/// - Sessions are rows of `sessions/sessions.db` (schema 18): `sessions(id, name, working_dir,
///   created_at, updated_at, archived_at, parent_session_id, …)` and `messages(session_id, role,
///   content_json, created_timestamp, …)`, which does not cascade (session_manager.rs#L1165-L1240).
/// - `goose session remove` always asks for confirmation on a terminal (crates/goose-cli/src/cli.rs#L519-L559),
///   so it cannot run from Domovy, and Domovy does not write to Goose's database itself.
/// - Keep `~/.config/goose/` (`config.yaml`, `secrets.yaml`).
struct GooseLayout: Sendable {
    let home: URL

    var dataFolders: [URL] {
        [home.appendingPathComponent(".local/share/goose", isDirectory: true),
         home.appendingPathComponent("Library/Application Support/Block/goose", isDirectory: true)]
    }
    var config: URL { home.appendingPathComponent(".config/goose", isDirectory: true) }
    var logs: URL { home.appendingPathComponent(".local/state/goose/logs", isDirectory: true) }

    /// Every `sessions.db` that exists.
    var databases: [URL] {
        dataFolders.map { $0.appendingPathComponent("sessions/sessions.db") }.filter { FileSystem.exists($0) }
    }

    static let requiredColumns: [String: Set<String>] = [
        "sessions": ["id", "name", "working_dir", "created_at", "updated_at"],
        "messages": ["session_id", "role", "content_json"],
    ]

    func unknownLayout(_ database: URL) -> String? {
        guard let reader = SQLiteReader(url: database) else { return "Domovy could not open Goose's sessions.db read-only." }
        for (table, columns) in Self.requiredColumns.sorted(by: { $0.key < $1.key }) {
            let missing = columns.subtracting(reader.columns(of: table))
            if !missing.isEmpty { return "Goose's sessions.db has a layout Domovy does not know (\(table) lacks \(missing.sorted().joined(separator: ", ")))." }
        }
        return nil
    }
}

/// Lists Goose's sessions read-only. Goose's own delete asks for confirmation and Domovy never
/// writes to Goose's database, so every plan is refused with that reason.
public struct GooseAdapter: AgentAdapter {
    public let kind: AgentKind = .goose
    public let root: URL

    let layout: GooseLayout
    let openHandles: any OpenHandleChecker

    public static let readOnlyReason = "Goose's own delete (`goose session remove`) always asks for confirmation, and Domovy does not write to Goose's database itself. Delete or archive sessions in Goose."

    public init(home: URL, openHandles: any OpenHandleChecker = LibprocOpenHandleChecker.shared) {
        self.layout = GooseLayout(home: home.standardizedFileURL)
        self.root = layout.dataFolders.first(where: FileSystem.isDirectory) ?? layout.dataFolders[0]
        self.openHandles = openHandles
    }

    public var scope: [URL] { layout.dataFolders }

    public func status() async -> AdapterStatus {
        guard layout.dataFolders.contains(where: FileSystem.isDirectory) else { return .notInstalled }
        if let reason = layout.databases.lazy.compactMap(layout.unknownLayout).first { return .readOnly(reason: reason + " Domovy only measures it.") }
        return .readOnly(reason: Self.readOnlyReason)
    }

    public func sessions() async throws -> [Session] {
        guard layout.dataFolders.contains(where: FileSystem.isDirectory) else { throw AdapterError.notInstalled(kind) }
        var result: [Session] = []
        for database in layout.databases where layout.unknownLayout(database) == nil {
            guard let reader = SQLiteReader(url: database) else { continue }
            let archived = reader.columns(of: "sessions").contains("archived_at") ? "s.archived_at" : "NULL"
            let live = await liveness(database)
            let sql = """
                SELECT s.id, s.name, s.working_dir, s.updated_at, s.created_at, \(archived),
                  (SELECT coalesce(sum(length(m.content_json)), 0) FROM messages m WHERE m.session_id = s.id)
                FROM sessions s
                """
            for cells in reader.rows(sql) where cells.count == 7 {
                guard let id = cells[0], !id.isEmpty else { continue }
                let isArchived = cells[5].map { !$0.isEmpty } ?? false
                result.append(Session(id: id, agent: kind, title: FileSessions.title(cells[1]), projectPath: cells[2].flatMap { $0.hasPrefix("/") ? $0 : nil },
                                      lastActive: Self.date(cells[3]) ?? Self.date(cells[4]) ?? .distantPast,
                                      sizeBytes: cells[6].flatMap { Int64($0) } ?? 0,
                                      status: live.isLive ? .live : isArchived ? .archived : .idle, expiresAt: nil,
                                      transcriptURL: database, isArchived: isArchived))
            }
        }
        return result.sorted { $0.lastActive > $1.lastActive }
    }

    public func artifacts(of session: Session) async throws -> [Artifact] {
        let database = try locate(session)
        return [Artifact(url: database, kind: .indexEntry, sizeBytes: session.sizeBytes, note: "Session and message rows in Goose's sessions.db")]
    }

    public func liveCheck(_ session: Session) async throws -> LiveCheckResult {
        await liveness(try locate(session))
    }

    public func deletePlan(for session: Session, destination: Destination = .trash) async throws -> Plan {
        _ = try locate(session)
        throw AdapterError.readOnly(kind, reason: Self.readOnlyReason)
    }

    public func archivePlan(for session: Session) async throws -> Plan {
        _ = try locate(session)
        throw AdapterError.readOnly(kind, reason: Self.readOnlyReason)
    }

    /// `content_json` is a list of parts; text parts are `{type: text, text}`.
    public func transcript(of session: Session, limit: Int, masking findings: [SecretFinding]) async throws -> Transcript {
        let database = try locate(session)
        guard let reader = SQLiteReader(url: database) else { return .empty }
        let masker = TranscriptMask.TextMasker()
        var messages: [TranscriptMessage] = []
        for cell in reader.rows("SELECT role, content_json FROM messages WHERE session_id = ?1 ORDER BY id LIMIT \(max(0, limit) * 4 + 1)", [session.id]) where cell.count == 2 {
            let role: TranscriptMessage.Role
            switch cell[0] {
            case "user": role = .user
            case "assistant": role = .assistant
            default: continue
            }
            guard let data = cell[1]?.data(using: .utf8), let parts = try? JSONSerialization.jsonObject(with: data),
                  let text = FileSessions.text(of: parts) else { continue }
            if messages.count == limit { return Transcript(messages: messages, isTruncated: true) }
            messages.append(TranscriptMessage(id: "g\(messages.count)", role: role, timestamp: nil, blocks: [.text(masker.mask(text))]))
        }
        return Transcript(messages: messages, isTruncated: false)
    }

    /// SQLite `CURRENT_TIMESTAMP` text (`2026-11-20 10:00:00`, UTC) or ISO 8601.
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        if let date = FileSessions.date(text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: String(text.prefix(19)))
    }

    private func liveness(_ database: URL) async -> LiveCheckResult {
        let holders = await openHandles.holders(of: SharedDatabaseLiveness.files(of: database), includingMapped: true)
        var reasons: [String] = []
        var seen = Set<Int32>()
        for holder in holders ?? [] where seen.insert(holder.pid).inserted {
            reasons.append("\(holder.processName) (pid \(holder.pid)) has Goose's sessions.db open.")
        }
        return LiveCheckResult(isLive: !reasons.isEmpty, reasons: reasons, checkedSignals: ["open file handles"],
                               openHandles: holders == nil ? .unavailable : reasons.isEmpty ? .clear : .open)
    }

    private func locate(_ session: Session) throws -> URL {
        let database = session.transcriptURL.standardizedFileURL
        guard session.agent == kind, layout.databases.map(\.standardizedFileURL).contains(database) else { throw AdapterError.sessionNotFound(session.id) }
        return database
    }
}

extension GooseAdapter {
    public func footprint() async throws -> Footprint {
        guard layout.dataFolders.contains(where: FileSystem.isDirectory) else { throw AdapterError.notInstalled(kind) }
        var builder = FootprintBuilder(agent: kind, root: root)
        builder.add("Sessions", layout.databases.flatMap(SharedDatabaseLiveness.files(of:)), reveal: root, .consequences,
                    "Goose's sessions.db. Remove sessions in Goose (`goose session remove`); Domovy only lists them.",
                    advice: "In Goose: goose session list, then goose session remove --session-id <id>.")
        builder.add("Logs", layout.logs, .safe, "Goose's logs. Remove them while Goose is quit.")
        builder.add("Settings and secrets", layout.config, .keep, "config.yaml and secrets.yaml. Domovy never removes them.")
        for (index, folder) in layout.dataFolders.enumerated() {
            builder.add(index == 0 ? "Other" : "Other (Application Support)", builder.unclaimedChildren(of: folder), reveal: folder, .keep,
                        "Older .jsonl sessions, caches and state. Left alone.")
        }
        return builder.build()
    }
}
