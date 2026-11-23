import Foundation

/// One thing on disk that belongs to a session: a file, a folder, or lines inside a shared index file.
public struct Artifact: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case file
        case folder
        /// Entries inside a file that is shared with other sessions (e.g. `history.jsonl`).
        /// The file itself stays; only the matching entries go.
        case indexEntry
    }

    public let url: URL
    public let kind: Kind
    public let sizeBytes: Int64
    /// One line that tells the user what this is ("Transcript", "Checkpoint snapshots").
    public let note: String
    /// For an `indexEntry` of JSON lines: the key and value that pick this session's lines.
    public let match: IndexMatch?

    public init(url: URL, kind: Kind, sizeBytes: Int64, note: String, match: IndexMatch? = nil) {
        self.url = url
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.note = note
        self.match = match
    }
}

/// Lines of a shared `.jsonl` file whose JSON object has `key` equal to `value`.
public struct IndexMatch: Hashable, Codable, Sendable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}
