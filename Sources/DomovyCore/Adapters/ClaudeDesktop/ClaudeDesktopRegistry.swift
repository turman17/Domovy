import Foundation

/// One Claude Code session as Claude Desktop lists it: a `local_<uuid>.json` registry file.
/// Only the fields Domovy needs are read; titles stay in memory and are never logged.
public struct DesktopRegistryEntry: Hashable, Codable, Sendable {
    /// The registry file, `claude-code-sessions/<uuid>/<uuid>/local_<uuid>.json`.
    public let file: URL
    /// Desktop's own id, `local_<uuid>`.
    public let desktopID: String
    /// The Claude Code transcript id (`~/.claude/projects/<slug>/<cliSessionId>.jsonl`).
    public let cliSessionID: String
    public let title: String?
    public let isArchived: Bool
    /// Transcript ids this conversation ran under before a Desktop restart (#89592).
    public let priorCLISessionIDs: [String]
    public let modificationDate: Date?
    public let sizeBytes: Int64
}

/// What a Claude Code session knows about its Desktop registry entry.
public struct DesktopLink: Hashable, Codable, Sendable {
    public let file: URL
    public let title: String?
    public let isArchived: Bool

    public init(file: URL, title: String?, isArchived: Bool) {
        self.file = file
        self.title = title
        self.isArchived = isArchived
    }
}

/// Reads Claude Desktop's list of Claude Code sessions (`claude-code-sessions/`). The layout
/// was verified on a real install (docs/research/agent_storage_formats.md); anything else
/// found there makes it read-only. Writes go through plans, only while Desktop is quit.
public struct ClaudeDesktopRegistry: Sendable {
    public let root: URL

    /// - Parameter directory: the `claude-code-sessions` folder. Tests pass a fixture copy.
    public init(directory: URL) {
        self.root = directory.standardizedFileURL
    }

    /// Convenience for a home directory.
    public init(home: URL) {
        self.init(directory: home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true))
    }

    /// Any process of the Claude desktop app: the main `Claude` process (case-sensitive, so
    /// the `claude` CLI does not count) and its Electron helpers.
    public static let processMatcher = ProcessMatcher(
        appName: "Claude Desktop",
        names: [],
        prefixes: ["claude helper"],
        exactNames: ["Claude"],
        quitAdvice: "Quit Claude Desktop to change its session list."
    )

    static let entryPrefix = "local_"
    /// Keys every verified entry has, with the type Domovy relies on.
    static let cliKey = "cliSessionId"

    /// Parsed entries and whether Domovy may change them.
    public struct Snapshot: Sendable {
        public let entries: [DesktopRegistryEntry]
        public let status: AdapterStatus

        public static let empty = Snapshot(entries: [], status: .notInstalled)

        public var canMutate: Bool { status.canMutate }

        /// Entries by transcript id. Several entries for one id are duplicates.
        public var byCLISessionID: [String: [DesktopRegistryEntry]] {
            Dictionary(grouping: entries, by: \.cliSessionID)
        }
    }

    /// Reads every entry. Names, sizes and four fields per file; nothing is logged.
    public func snapshot() -> Snapshot {
        guard FileSystem.isDirectory(root) else { return .empty }
        var entries: [DesktopRegistryEntry] = []
        var problems: [String] = []
        for file in Self.registryFiles(below: root) {
            let relative = FileSystem.relativePath(of: file, under: root) ?? ""
            let parts = relative.split(separator: "/").map(String.init)
            guard parts.count == 3, ClaudeCodeLayout.isUUID(parts[0]), ClaudeCodeLayout.isUUID(parts[1]) else {
                problems.append("an entry outside the usual <id>/<id>/ folders")
                continue
            }
            guard let entry = Self.parse(file) else {
                problems.append("an entry without the fields Domovy knows")
                continue
            }
            entries.append(entry)
        }
        let status: AdapterStatus = problems.isEmpty
            ? .ready
            : .readOnly(reason: "Claude Desktop's session list has \(problems[0]). It may be a newer Desktop; Domovy leaves the list as it is.")
        return Snapshot(entries: entries.sorted { $0.file.path < $1.file.path }, status: status)
    }

    /// `local_*.json` files at any depth, so an unexpected place is noticed, not skipped.
    static func registryFiles(below root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .map(\.standardizedFileURL)
            .filter { $0.lastPathComponent.hasPrefix(entryPrefix) && $0.pathExtension == "json" && !FileSystem.isDirectory($0) }
    }

    static func parse(_ file: URL) -> DesktopRegistryEntry? {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let desktopID = object["sessionId"] as? String,
              let cli = object[cliKey] as? String, ClaudeCodeLayout.isUUID(cli) else { return nil }
        let title = (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return DesktopRegistryEntry(
            file: file,
            desktopID: desktopID,
            cliSessionID: cli.lowercased(),
            title: title,
            isArchived: object["isArchived"] as? Bool ?? false,
            priorCLISessionIDs: (object["priorCliSessionIds"] as? [String] ?? []).filter(ClaudeCodeLayout.isUUID).map { $0.lowercased() },
            modificationDate: FileSystem.modificationDate(of: file),
            sizeBytes: FileSystem.size(of: file)
        )
    }

    /// The plan item that takes one entry off Desktop's list.
    static func removal(of entry: DesktopRegistryEntry, note: String) -> RegistryRemoval {
        RegistryRemoval(
            file: entry.file,
            matchKey: cliKey,
            matchValue: entry.cliSessionID,
            sizeBytes: entry.sizeBytes,
            note: note
        )
    }
}
