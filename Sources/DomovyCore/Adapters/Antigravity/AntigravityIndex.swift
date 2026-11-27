import Foundation

/// Titles, previews and workspaces of a store's conversations, from `conversation_summaries.db`
/// (read only) and `cache/conversation_metadata.json`. Values are shown, never logged.
struct AntigravityIndex: Sendable {
    struct Entry: Sendable {
        var title: String?
        /// The summary's preview, first line only: a fallback when there is no title.
        var preview: String?
        var workspace: String?
    }

    let entries: [String: Entry]

    static func load(_ store: AntigravityStore) -> AntigravityIndex {
        var entries: [String: Entry] = [:]
        if let data = try? Data(contentsOf: store.metadataCache), data.count < 16_000_000,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let conversations = object["conversations"] as? [String: Any] {
            for (id, value) in conversations {
                guard let summary = (value as? [String: Any])?["summary"] as? [String: Any] else { continue }
                let uris = summary["WorkspaceURIs"] as? [String] ?? []
                entries[id.lowercased()] = Entry(title: clean(summary["Title"] as? String), preview: clean(summary["Preview"] as? String),
                                                 workspace: uris.compactMap(path).first)
            }
        }
        // The summaries database is the newer source; it wins where both have a value.
        if let reader = SQLiteReader(url: store.summaries), reader.tables().contains("conversation_summaries") {
            let hasPreview = reader.columns(of: "conversation_summaries").contains("preview")
            let query = "SELECT conversation_id, title, workspace_uris\(hasPreview ? ", preview" : "") FROM conversation_summaries"
            for row in reader.rows(query) where row.count == (hasPreview ? 4 : 3) {
                guard let id = row[0]?.lowercased() else { continue }
                var entry = entries[id] ?? Entry()
                entry.title = clean(row[1]) ?? entry.title
                entry.workspace = workspace(fromJSON: row[2]) ?? entry.workspace
                if hasPreview { entry.preview = clean(row[3]) ?? entry.preview }
                entries[id] = entry
            }
        }
        return AntigravityIndex(entries: entries)
    }

    /// `["file:///Users/dev/code/app"]` → `/Users/dev/code/app`.
    private static func workspace(fromJSON text: String?) -> String? {
        guard let data = text?.data(using: .utf8), let uris = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
        return uris.compactMap(path).first
    }

    private static func path(_ uri: String) -> String? {
        guard let url = URL(string: uri), url.isFileURL, !url.path.isEmpty else { return nil }
        return url.path
    }

    /// The shared title cleanup (agent context tags, markdown) and the first line, capped.
    /// Text that starts with a wrapper tag is cleaned whole, since the tag may span lines.
    static func clean(_ text: String?) -> String? {
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let first = raw.hasPrefix("<") ? raw : raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
        guard let line = Session.cleanTitle(first) else { return nil }
        return line.count > 120 ? String(line.prefix(119)) + "\u{2026}" : line
    }
}

/// What a delete changes in a store's three indexes, read once for a batch: the conversation's
/// row of `conversation_summaries.db`, its member of `cache/conversation_metadata.json` and its
/// lines of `history.jsonl`. An index whose shape is not the verified one is left alone, with a
/// remark, never guessed at.
struct AntigravityIndexEdits {
    static let summariesTable = "conversation_summaries"
    static let summariesKey = "conversation_id"
    static let metadataField = "conversations"
    static let historyKey = "conversationId"

    struct Edits {
        var history: IndexEdit?
        var summaries: DatabaseEdit?
        var metadata: JSONMemberRemoval?
        var remarks: [String] = []
    }

    let store: AntigravityStore
    private let history: CodexIndex.LineLookup
    /// Row ids as stored and the bytes of their text, by lowercased id; `nil` when the database
    /// is missing; `.unknown` when its shape is not the verified one.
    private let summaries: Shape<[String: (id: String, bytes: Int64)]>
    /// Member byte counts by lowercased id.
    private let metadata: Shape<[String: Int64]>

    enum Shape<Value> {
        case absent
        case unknown
        case known(Value)
    }

    init(_ store: AntigravityStore) {
        self.store = store
        history = CodexIndex.LineLookup(store.history, key: Self.historyKey)
        if !FileSystem.exists(store.summaries) {
            summaries = .absent
        } else if let reader = SQLiteReader(url: store.summaries), reader.tables().contains(Self.summariesTable),
                  case let columns = reader.columns(of: Self.summariesTable), columns.contains(Self.summariesKey) {
            var rows: [String: (id: String, bytes: Int64)] = [:]
            // Bytes of the text columns there are, for the plan's size.
            let text = ["title", "preview", "workspace_uris"].filter(columns.contains).map { "coalesce(length(\($0)), 0)" }
            let size = text.isEmpty ? "0" : text.joined(separator: " + ")
            for row in reader.rows("SELECT \(Self.summariesKey), \(size) FROM \(Self.summariesTable)") where row.count == 2 {
                guard let id = row[0] else { continue }
                let bytes = Int64(row[1] ?? "") ?? 0
                rows[id.lowercased(), default: (id, 0)].bytes += bytes + Int64(id.utf8.count)
            }
            summaries = .known(rows)
        } else {
            summaries = .unknown
        }
        if !FileSystem.exists(store.metadataCache) {
            metadata = .absent
        } else if FileSystem.size(of: store.metadataCache) < 64_000_000, let data = try? Data(contentsOf: store.metadataCache),
                  let members = JSONListCut.members(in: data, field: Self.metadataField) {
            var sizes: [String: Int64] = [:]
            for member in members { if let key = member.key { sizes[key.lowercased(), default: 0] += Int64(member.range.count) } }
            metadata = .known(sizes)
        } else {
            metadata = .unknown
        }
    }

    func edits(id: String) -> Edits {
        var edits = Edits()
        edits.history = history.edit(id: id)
        switch summaries {
        case .absent: break
        case .unknown:
            edits.remarks.append("conversation_summaries.db has a layout Domovy does not know, so Domovy leaves it; Antigravity may still list this conversation.")
        case .known(let rows):
            if let row = rows[id.lowercased()] {
                edits.summaries = DatabaseEdit(
                    database: store.summaries, files: store.summariesFiles,
                    rows: [.init(table: Self.summariesTable, key: row.id, isPrefix: false, count: 1, bytes: row.bytes,
                                 note: "Its entry in Antigravity's conversation list", column: Self.summariesKey)],
                    listRemovals: []
                )
            }
        }
        switch metadata {
        case .absent: break
        case .unknown:
            edits.remarks.append("cache/conversation_metadata.json has a shape Domovy does not know, so Domovy leaves it.")
        case .known(let sizes):
            if let bytes = sizes[id.lowercased()] {
                edits.metadata = JSONMemberRemoval(file: store.metadataCache, field: Self.metadataField, key: id, sizeBytes: bytes,
                                                   note: "Its entry in Antigravity's metadata cache; the other entries stay byte for byte")
            }
        }
        return edits
    }
}
