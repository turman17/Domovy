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

    /// A file an archive compressed in place; undo decompresses it again.
    public struct CompressedItem: Codable, Sendable, Hashable {
        public let file: URL
        public let sizeBytes: Int64
    }

    public let id: UUID
    public let createdAt: Date
    public let planID: UUID
    /// Entries executed together (e.g. "Archive all") share an id and are undone together.
    public let batchID: UUID?
    public let action: Plan.Action
    public let agent: AgentKind
    public let sessionID: String
    public let destination: Destination?
    public var moved: [MovedItem]
    public var indexRestores: [IndexRestore]
    public var compressed: [CompressedItem]
    /// Agent commands that reverse what the plan's commands did (e.g. `codex unarchive`).
    public var undoCommands: [PlannedCommand]
    /// Apps that must not run while undo runs `undoCommands` or rewrites their index.
    public var mustNotBeRunning: [ProcessMatcher]
    /// What an agent command left behind, found by checking after it ran.
    public var leftovers: [String]
    public var undoneAt: Date?
    /// Set when execution stopped half way; `undo` still restores what did move.
    public var failure: String?

    public var isUndone: Bool { undoneAt != nil }
}

extension UndoEntry {
    private enum CodingKeys: String, CodingKey {
        case id, createdAt, planID, batchID, action, agent, sessionID, destination
        case moved, indexRestores, compressed, undoCommands, mustNotBeRunning, leftovers, undoneAt, failure
    }

    /// Entries written by older versions lack the newer fields; they decode with empty defaults.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            createdAt: try c.decode(Date.self, forKey: .createdAt),
            planID: try c.decode(UUID.self, forKey: .planID),
            batchID: try c.decodeIfPresent(UUID.self, forKey: .batchID),
            action: try c.decodeIfPresent(Plan.Action.self, forKey: .action) ?? .delete,
            agent: try c.decode(AgentKind.self, forKey: .agent),
            sessionID: try c.decode(String.self, forKey: .sessionID),
            destination: try c.decodeIfPresent(Destination.self, forKey: .destination),
            moved: try c.decodeIfPresent([MovedItem].self, forKey: .moved) ?? [],
            indexRestores: try c.decodeIfPresent([IndexRestore].self, forKey: .indexRestores) ?? [],
            compressed: try c.decodeIfPresent([CompressedItem].self, forKey: .compressed) ?? [],
            undoCommands: try c.decodeIfPresent([PlannedCommand].self, forKey: .undoCommands) ?? [],
            mustNotBeRunning: try c.decodeIfPresent([ProcessMatcher].self, forKey: .mustNotBeRunning) ?? [],
            leftovers: try c.decodeIfPresent([String].self, forKey: .leftovers) ?? [],
            undoneAt: try c.decodeIfPresent(Date.self, forKey: .undoneAt),
            failure: try c.decodeIfPresent(String.self, forKey: .failure)
        )
    }
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

    /// The latest pending entry together with the pending entries of its batch, newest first.
    public func latestPendingBatch() throws -> [UndoEntry] {
        let pending = try entries().filter { !$0.isUndone }
        guard let last = pending.last else { return [] }
        guard let batch = last.batchID else { return [last] }
        return pending.filter { $0.batchID == batch }.reversed()
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
