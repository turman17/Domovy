import Foundation

/// Titles and workspaces of a store's conversations, from `conversation_summaries.db` (read
/// only) and `cache/conversation_metadata.json`. Values are shown, never logged.
struct AntigravityIndex: Sendable {
    struct Entry: Sendable {
        var title: String?
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
                entries[id.lowercased()] = Entry(title: clean(summary["Title"] as? String), workspace: uris.compactMap(path).first)
            }
        }
        // The summaries database is the newer source; it wins where both have a value.
        if let reader = SQLiteReader(url: store.summaries), reader.tables().contains("conversation_summaries") {
            for row in reader.rows("SELECT conversation_id, title, workspace_uris FROM conversation_summaries") where row.count == 3 {
                guard let id = row[0]?.lowercased() else { continue }
                var entry = entries[id] ?? Entry()
                entry.title = clean(row[1]) ?? entry.title
                entry.workspace = workspace(fromJSON: row[2]) ?? entry.workspace
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

    private static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return nil }
        return line.count > 120 ? String(line.prefix(119)) + "\u{2026}" : line
    }
}
