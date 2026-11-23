import Foundation

/// Cursor 3.0+'s chat list, `composer.composerHeaders` in `ItemTable`. Its shape is reported
/// (cursaves), not verified: the install Domovy was built on predates it. Read as
/// `{"allComposers": [{composerId, name?, createdAt?, lastUpdatedAt?, workspaceIdentifier?: {id, uri}}]}`
/// or as that list alone. Anything else is unknown, and Domovy then edits no Cursor chat.
enum CursorHeaders {
    struct Entry: Sendable {
        let id: String
        let name: String?
        let createdAt: Date?
        let updatedAt: Date?
        /// The workspace folder, from `workspaceIdentifier.uri`.
        let workspace: String?
    }

    enum State: Sendable {
        /// No chat list (Cursor before 3.0, as on the verified install).
        case absent
        /// `listField` is where the list sits in the value (`allComposers`), `nil` for a bare list.
        case known(listField: String?, entries: [String: Entry])
        case unknown
    }

    static let listField = "allComposers"
    static let idField = "composerId"

    static func load(_ reader: SQLiteReader) -> State {
        let rows = reader.rows("SELECT CAST(value AS TEXT) FROM ItemTable WHERE key = ?1", [CursorLayout.headersKey])
        guard let first = rows.first else { return .absent }
        guard let text = first.first ?? nil else { return .unknown }
        return parse(Data(text.utf8))
    }

    static func parse(_ data: Data) -> State {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return .unknown }
        let field: String?
        let list: [Any]
        if let object = json as? [String: Any], let entries = object[listField] as? [Any] {
            field = listField
            list = entries
        } else if let entries = json as? [Any] {
            field = nil
            list = entries
        } else {
            return .unknown
        }
        // The cut must find the same list, or Domovy could not edit it byte for byte.
        guard JSONListCut.entries(in: data, field: field)?.count == list.count else { return .unknown }
        var entries: [String: Entry] = [:]
        for item in list {
            guard let object = item as? [String: Any], let id = object[idField] as? String, !id.isEmpty else { return .unknown }
            entries[id] = Entry(
                id: id,
                name: (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                createdAt: date(object["createdAt"]),
                updatedAt: date(object["lastUpdatedAt"]),
                workspace: workspacePath(object["workspaceIdentifier"])
            )
        }
        return .known(listField: field, entries: entries)
    }

    /// Milliseconds since 1970.
    static func date(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber, number.doubleValue > 0 else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue / 1000)
    }

    /// `uri` as a `file://` string, or as a VS Code URI object with `fsPath` or `path`.
    static func workspacePath(_ value: Any?) -> String? {
        guard let identifier = value as? [String: Any] else { return nil }
        if let uri = identifier["uri"] as? String, let url = URL(string: uri), url.isFileURL { return url.path }
        if let uri = identifier["uri"] as? [String: Any] {
            return (uri["fsPath"] as? String) ?? (uri["path"] as? String)
        }
        return nil
    }
}
