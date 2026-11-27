import CryptoKit
import Foundation

/// Amazon Q Developer CLI, read from aws/amazon-q-developer-cli@15cc8f3c (maintenance only; Kiro CLI
/// replaces it; docs/research/agent_storage_formats.md, Q9; not verified on a real install). Permalink base:
/// https://github.com/aws/amazon-q-developer-cli/blob/15cc8f3cd18c4272925ce1c7053268eedff1ea0a/
///
/// - Everything is in `~/Library/Application Support/amazon-q/data.sqlite3` (crates/chat-cli/src/util/paths.rs#L327-L332).
/// - `conversations(key = absolute folder, value = JSON ConversationState)` keeps one conversation per
///   folder (crates/chat-cli/src/database/sqlite_migrations/007_conversations_table.sql#L1-L4,
///   crates/chat-cli/src/cli/chat/conversation.rs#L107-L110).
/// - The same database holds the sign-in (`state`, `auth_kv`; migrations 004-006), so Domovy never
///   writes to it, not even with Amazon Q quit.
struct AmazonQLayout: Sendable {
    let support: URL

    var database: URL { support.appendingPathComponent("data.sqlite3") }
}

/// Lists Amazon Q CLI conversations read-only; every plan is refused.
public struct AmazonQAdapter: AgentAdapter {
    public let kind: AgentKind = .amazonQ
    public let root: URL

    let layout: AmazonQLayout
    let openHandles: any OpenHandleChecker

    public static let readOnlyReason = "Amazon Q CLI keeps its sign-in in the same database as its conversations, so Domovy never changes it. Start over in a folder with /clear in q chat."

    public init(supportDirectory: URL, openHandles: any OpenHandleChecker = LibprocOpenHandleChecker()) {
        self.root = supportDirectory.standardizedFileURL
        self.layout = AmazonQLayout(support: self.root)
        self.openHandles = openHandles
    }

    public init(home: URL) {
        self.init(supportDirectory: home.appendingPathComponent("Library/Application Support/amazon-q", isDirectory: true), openHandles: LibprocOpenHandleChecker.shared)
    }

    private var knownLayout: Bool {
        guard let reader = SQLiteReader(url: layout.database) else { return false }
        return reader.columns(of: "conversations").isSuperset(of: ["key", "value"])
    }

    public func status() async -> AdapterStatus {
        guard FileSystem.isDirectory(root) else { return .notInstalled }
        guard FileSystem.exists(layout.database), knownLayout else {
            return .readOnly(reason: "Amazon Q CLI's data.sqlite3 has no conversations table Domovy knows, so it only measures the folder.")
        }
        return .readOnly(reason: Self.readOnlyReason)
    }

    public func sessions() async throws -> [Session] {
        guard FileSystem.isDirectory(root) else { throw AdapterError.notInstalled(kind) }
        guard knownLayout, let reader = SQLiteReader(url: layout.database) else { return [] }
        let modified = FileSystem.modificationDate(of: layout.database) ?? .distantPast
        let live = await liveness()
        return reader.rows("SELECT key, length(value), json_extract(value, '$.conversation_id') FROM conversations").compactMap { cells in
            guard cells.count == 3, let key = cells[0], key.hasPrefix("/") else { return nil }
            let id = cells[2].flatMap { SafeID.isSafe($0) ? $0 : nil } ?? Self.id(for: key)
            return Session(id: id, agent: kind, title: "Conversation in \(URL(fileURLWithPath: key).lastPathComponent)", projectPath: key,
                           lastActive: modified, sizeBytes: cells[1].flatMap { Int64($0) } ?? 0,
                           status: live.isLive ? .live : .idle, expiresAt: nil, transcriptURL: layout.database)
        }
    }

    static func id(for key: String) -> String {
        "q-" + SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public func artifacts(of session: Session) async throws -> [Artifact] {
        [Artifact(url: layout.database, kind: .indexEntry, sizeBytes: session.sizeBytes, note: "One row of data.sqlite3, which also holds the sign-in")]
    }

    public func liveCheck(_ session: Session) async throws -> LiveCheckResult { await liveness() }

    public func deletePlan(for session: Session, destination: Destination = .trash) async throws -> Plan {
        throw AdapterError.readOnly(kind, reason: Self.readOnlyReason)
    }

    public func archivePlan(for session: Session) async throws -> Plan {
        throw AdapterError.readOnly(kind, reason: Self.readOnlyReason)
    }

    /// The conversation JSON is Amazon Q's internal state; Domovy does not show it.
    public func transcript(of session: Session, limit: Int, masking findings: [SecretFinding]) async throws -> Transcript { .empty }

    private func liveness() async -> LiveCheckResult {
        let holders = await openHandles.holders(of: SharedDatabaseLiveness.files(of: layout.database), includingMapped: true)
        let reasons = Set((holders ?? []).map(\.pid)).sorted().map { "Process \($0) has Amazon Q CLI's database open." }
        return LiveCheckResult(isLive: !reasons.isEmpty, reasons: reasons, checkedSignals: ["open file handles"],
                               openHandles: holders == nil ? .unavailable : reasons.isEmpty ? .clear : .open)
    }
}

extension AmazonQAdapter {
    public func footprint() async throws -> Footprint {
        guard FileSystem.isDirectory(root) else { throw AdapterError.notInstalled(kind) }
        var builder = FootprintBuilder(agent: kind, root: root)
        builder.add("Conversations and sign-in", SharedDatabaseLiveness.files(of: layout.database), reveal: root, .keep,
                    "One database holds Amazon Q's conversations and its sign-in. Domovy never changes it.",
                    advice: "In q chat, /clear starts the conversation of a folder over.")
        builder.add("Other", builder.unclaimedChildren(of: root), reveal: root, .keep, "Settings, logs and state. Left alone.")
        return builder.build()
    }
}
