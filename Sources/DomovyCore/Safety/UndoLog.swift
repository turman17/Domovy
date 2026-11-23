import Foundation

/// What one executed plan did, with everything needed to put it back.
public struct UndoEntry: Identifiable, Codable, Sendable {
    public struct MovedItem: Codable, Sendable, Hashable {
        public let original: URL
        /// Where the item is now (inside the Trash or the quarantine folder).
        public let current: URL
    }

    public struct RemovedLine: Codable, Sendable, Hashable {
        /// Zero-based index in the file at execution time.
        public let index: Int
        public let bytes: Data
    }

    public struct IndexRestore: Codable, Sendable, Hashable {
        public let file: URL
        /// Byte-exact copy of the file before the edit, kept next to the entry.
        public let backup: URL
        public let removedLines: [RemovedLine]
        public let modificationTime: FileTime?
    }

    public let id: UUID
    public let createdAt: Date
    public let planID: UUID
    public let agent: AgentKind
    public let sessionID: String
    public let destination: Destination
    public var moved: [MovedItem]
    public var indexRestores: [IndexRestore]
    public var undoneAt: Date?
    /// Set when execution stopped half way; `undo` still restores what did move.
    public var failure: String?

    public var isUndone: Bool { undoneAt != nil }
}

/// A folder of JSON entries, newest last. Lives under the Domovy store root, never in `~/.claude`.
public struct UndoLog: Sendable {
    public let directory: URL
    var fileManager: FileManager { .default }

    public init(directory: URL) {
        self.directory = directory
    }

    public func entries() throws -> [UndoEntry] {
        guard FileSystem.exists(directory) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try FileSystem.children(of: directory)
            .filter { $0.pathExtension == "json" }
            .map { try decoder.decode(UndoEntry.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func latestPending() throws -> UndoEntry? {
        try entries().last { !$0.isUndone }
    }

    /// Folder for backups that belong to one entry.
    func backupDirectory(for entry: UndoEntry) -> URL {
        directory.appendingPathComponent(entry.id.uuidString, isDirectory: true)
    }

    func write(_ entry: UndoEntry) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entry)
        // Entries can contain prompt text from history.jsonl, so keep them owner-only.
        try data.write(to: url(for: entry), options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(for: entry).path)
    }

    private func url(for entry: UndoEntry) -> URL {
        let stamp = ISO8601DateFormatter().string(from: entry.createdAt).replacingOccurrences(of: ":", with: "-")
        return directory.appendingPathComponent("\(stamp)-\(entry.id.uuidString).json")
    }
}
