import Foundation

/// Where removed files go. Domovy never unlinks by default.
public enum Destination: String, Codable, Sendable {
    case trash
    case quarantine

    public var displayName: String {
        switch self {
        case .trash: "the Trash"
        case .quarantine: "the Domovy quarantine folder"
        }
    }
}

/// One file or folder that will be moved out of the agent's storage.
public struct FileMove: Hashable, Codable, Sendable {
    public let source: URL
    public let kind: Artifact.Kind
    public let sizeBytes: Int64
    public let note: String

    public init(source: URL, kind: Artifact.Kind, sizeBytes: Int64, note: String) {
        self.source = source
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.note = note
    }
}

/// Lines to remove from a shared index file. The file itself is kept, with its mtime.
public struct IndexEdit: Hashable, Codable, Sendable {
    public let file: URL
    /// Zero-based line numbers at plan time. The executor re-matches by `matchKey` so a
    /// file that grew in the meantime is still edited correctly.
    public let lineNumbers: [Int]
    /// The JSON key and value every removed line must carry (e.g. `sessionId` = uuid).
    public let matchKey: String
    public let matchValue: String
    public let removedBytes: Int64
    public let note: String

    public init(file: URL, lineNumbers: [Int], matchKey: String, matchValue: String, removedBytes: Int64, note: String) {
        self.file = file
        self.lineNumbers = lineNumbers
        self.matchKey = matchKey
        self.matchValue = matchValue
        self.removedBytes = removedBytes
        self.note = note
    }
}

/// A whole index file that leaves an app's list, such as one Claude Desktop registry entry
/// (`local_<uuid>.json`). The executor backs it up first and moves it like any other file;
/// undo puts it back with its modification time.
public struct RegistryRemoval: Hashable, Codable, Sendable {
    public let file: URL
    /// The executor removes the file only if its JSON still carries this key and value.
    public let matchKey: String
    public let matchValue: String
    public let sizeBytes: Int64
    public let note: String

    public init(file: URL, matchKey: String, matchValue: String, sizeBytes: Int64, note: String) {
        self.file = file
        self.matchKey = matchKey
        self.matchValue = matchValue
        self.sizeBytes = sizeBytes
        self.note = note
    }
}

/// One member cut out of an object inside an app's JSON file, such as one conversation of
/// Antigravity's `cache/conversation_metadata.json` (`{"conversations": {"<id>": …}}`). Every
/// other byte stays. The executor clones the file first and keeps its modification time; undo
/// puts the clone back only while the file is exactly as the edit left it.
public struct JSONMemberRemoval: Hashable, Codable, Sendable {
    public let file: URL
    /// The member of the top-level object that holds the object to cut from.
    public let field: String
    /// The key of the member to cut, compared ignoring case.
    public let key: String
    public let sizeBytes: Int64
    public let note: String
    /// Set to cut entries of a JSON list instead: the entries whose `idField` is `key`, of the
    /// array under `field` (empty: the top-level array, like Continue's `sessions.json`).
    public let idField: String?

    public init(file: URL, field: String, key: String, sizeBytes: Int64, note: String, idField: String? = nil) {
        self.file = file
        self.field = field
        self.key = key
        self.sizeBytes = sizeBytes
        self.note = note
        self.idField = idField
    }
}

/// A file or folder that moves to another place inside the agent's own folder, the way the
/// agent archives a session itself (Qwen Code's `chats/archive/`). A rename on one volume, so
/// modification times stay; undo moves it back. Nothing leaves the agent's folder.
public struct FileRelocation: Hashable, Codable, Sendable {
    public let source: URL
    /// Where it goes. The executor refuses when something is already there.
    public let target: URL
    public let kind: Artifact.Kind
    public let sizeBytes: Int64
    public let note: String

    public init(source: URL, target: URL, kind: Artifact.Kind, sizeBytes: Int64, note: String) {
        self.source = source
        self.target = target
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.note = note
    }
}

/// One file that an archive rewrites in place with APFS transparent compression.
/// The agent reads it exactly as before; only the on-disk size changes.
public struct FileCompression: Hashable, Codable, Sendable {
    public let file: URL
    /// Bytes on disk now. The logical size never changes.
    public let sizeBytes: Int64
    /// Estimated bytes on disk afterwards.
    public let estimatedBytes: Int64
    /// Modification time at plan time. The executor leaves a file alone if it changed since.
    public let modificationTime: FileTime?
    public let note: String

    public init(file: URL, sizeBytes: Int64, estimatedBytes: Int64, modificationTime: FileTime?, note: String) {
        self.file = file
        self.sizeBytes = sizeBytes
        self.estimatedBytes = estimatedBytes
        self.modificationTime = modificationTime
        self.note = note
    }
}

/// Exact description of a mutating action, computed before anything changes.
/// The same value drives the UI preview, `domo rm --dry-run` and the executor.
public struct Plan: Identifiable, Hashable, Codable, Sendable {
    public enum Action: String, Codable, Sendable {
        case delete
        case archive
        /// Rewrites lines with secrets replaced; the original goes to the quarantine.
        case redact
    }

    public let id: UUID
    public let createdAt: Date
    public let agent: AgentKind
    public let sessionID: String
    public let action: Action
    /// Where moved files go. `nil` for an archive, which changes files in place.
    public let destination: Destination?
    public let moves: [FileMove]
    public let indexEdits: [IndexEdit]
    /// Index files removed whole (Claude Desktop registry entries).
    public let registryRemovals: [RegistryRemoval]
    public let compressions: [FileCompression]
    /// Files moved within the agent's folder (an archive the agent itself understands).
    public let relocations: [FileRelocation]
    /// The agent's own commands, run before any move or edit (e.g. `codex delete`).
    public let commands: [PlannedCommand]
    /// Rows Domovy deletes from an app's database itself, after the commands and before any
    /// move (Cursor's `state.vscdb`, which has no command for one chat).
    public let databaseEdits: [DatabaseEdit]
    /// Members Domovy cuts out of an app's JSON index (Antigravity's metadata cache), after the
    /// database edits and before any move.
    public let jsonRemovals: [JSONMemberRemoval]
    /// Files a redaction rewrites, with every value it replaces.
    public let redactions: [FileRedaction]
    /// Findings a redaction leaves alone, each with the reason.
    public let skippedSecrets: [SkippedSecret]
    /// Possible secrets the scan found in this session. Set by the caller before a delete, so
    /// the undo entry knows its quarantined files hold plaintext secrets and can be purged.
    public var secretFindingCount = 0
    /// Consequences the user should know before confirming ("3 rows stay in state_5.sqlite").
    public let remarks: [String]
    /// A consequence the user must accept explicitly before the plan runs, e.g. that undo
    /// stops working once OpenCode writes to its database again. The executor refuses the plan
    /// until `isAcknowledged` is set.
    public let acknowledgement: String?
    /// Set by the caller once the user accepted `acknowledgement` (a checkbox in the sheet,
    /// `--accept-limited-undo` in the CLI).
    public var isAcknowledged = false
    /// Apps that must not run while this plan executes; the executor checks again right before.
    public let mustNotBeRunning: [ProcessMatcher]
    public var liveCheck: LiveCheckResult
    /// The folders this plan may change: the adapter's root (or roots). The executor refuses any
    /// path outside them, so an id read from the agent's data can never point a move elsewhere.
    public let scope: [URL]

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        agent: AgentKind,
        sessionID: String,
        action: Action,
        destination: Destination?,
        moves: [FileMove],
        indexEdits: [IndexEdit],
        registryRemovals: [RegistryRemoval] = [],
        compressions: [FileCompression] = [],
        relocations: [FileRelocation] = [],
        commands: [PlannedCommand] = [],
        databaseEdits: [DatabaseEdit] = [],
        jsonRemovals: [JSONMemberRemoval] = [],
        redactions: [FileRedaction] = [],
        skippedSecrets: [SkippedSecret] = [],
        remarks: [String] = [],
        acknowledgement: String? = nil,
        mustNotBeRunning: [ProcessMatcher] = [],
        liveCheck: LiveCheckResult,
        scope: [URL] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.agent = agent
        self.sessionID = sessionID
        self.action = action
        self.destination = destination
        self.moves = moves
        self.indexEdits = indexEdits
        self.registryRemovals = registryRemovals
        self.compressions = compressions
        self.relocations = relocations
        self.commands = commands
        self.databaseEdits = databaseEdits
        self.jsonRemovals = jsonRemovals
        self.redactions = redactions
        self.skippedSecrets = skippedSecrets
        self.remarks = remarks
        self.acknowledgement = acknowledgement
        self.mustNotBeRunning = mustNotBeRunning
        self.liveCheck = liveCheck
        self.scope = scope.map(\.standardizedFileURL)
    }

    public var totalBytes: Int64 {
        moves.reduce(0) { $0 + $1.sizeBytes } + indexEdits.reduce(0) { $0 + $1.removedBytes }
            + registryRemovals.reduce(0) { $0 + $1.sizeBytes }
            + compressions.reduce(0) { $0 + $1.sizeBytes } + commands.reduce(0) { $0 + $1.sizeBytes }
            + databaseEdits.reduce(0) { $0 + $1.sizeBytes } + jsonRemovals.reduce(0) { $0 + $1.sizeBytes }
            + relocations.reduce(0) { $0 + $1.sizeBytes }
    }

    /// Estimated on-disk bytes of the compressed files after an archive.
    public var estimatedBytesAfter: Int64 {
        compressions.reduce(0) { $0 + $1.estimatedBytes }
    }

    /// A command runs that Domovy keeps a copy for first (`codex delete`, `ollama rm`); the
    /// space comes back only once that copy is purged.
    public var keepsToolCopies: Bool {
        commands.contains { !Executor.filesToKeep($0).isEmpty }
    }

    /// The user still has to accept `acknowledgement` before the plan may run.
    public var needsAcknowledgement: Bool {
        acknowledgement != nil && !isAcknowledged
    }

    public var isEmpty: Bool {
        moves.isEmpty && indexEdits.isEmpty && registryRemovals.isEmpty && compressions.isEmpty && relocations.isEmpty && commands.isEmpty && redactions.isEmpty
            && databaseEdits.allSatisfy(\.isEmpty) && jsonRemovals.isEmpty
    }

    /// Values a redaction replaces, across all files.
    public var redactionCount: Int {
        redactions.reduce(0) { $0 + $1.replacementCount }
    }

    /// Plain-language summary in the Domovy voice: say exactly what happens.
    public var summary: String {
        if liveCheck.isLive {
            let lead = commands.isEmpty && mustNotBeRunning.isEmpty ? "This session is live, so nothing will change." : "Nothing will change yet."
            return lead + " " + liveCheck.reasons.joined(separator: " ")
        }
        // The tool deletes for good: say that, and that Domovy keeps a copy.
        if isPermanent { return modelSummary }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        let commandText = commands.map(\.note).joined(separator: " ")
        if action == .archive, !commands.isEmpty {
            return commandText + " You can undo this."
        }
        if action == .redact { return redactionSummary }
        if action == .archive, !relocations.isEmpty {
            let n = relocations.count
            let bytes = formatter.string(fromByteCount: relocations.reduce(0) { $0 + $1.sizeBytes })
            let folder = relocations[0].target.deletingLastPathComponent().lastPathComponent
            return "Moves \(n) \(n == 1 ? "file" : "files") (\(bytes)) into \(folder)/, where \(agent.displayName) lists the session as archived. Nothing is deleted. You can undo this."
        }
        if action == .archive {
            guard !compressions.isEmpty else {
                return remarks.first ?? "Nothing to compress: the files of this session are already compressed or too small to gain from it."
            }
            let n = compressions.count
            let before = formatter.string(fromByteCount: totalBytes)
            let after = formatter.string(fromByteCount: estimatedBytesAfter)
            return "Compresses \(n) \(n == 1 ? "file" : "files") (\(before) \u{2192} ~\(after)). \(agent.displayName) can still resume it. You can undo this."
        }
        var parts: [String] = []
        if !moves.isEmpty {
            let bytes = formatter.string(fromByteCount: moves.reduce(0) { $0 + $1.sizeBytes })
            parts.append("Moves \(moves.count) \(moves.count == 1 ? "item" : "items") (\(bytes)) to \((destination ?? .trash).displayName)")
        }
        for edit in indexEdits {
            let n = edit.lineNumbers.count
            parts.append("removes \(n) \(n == 1 ? "line" : "lines") from \(edit.file.lastPathComponent)")
        }
        if !registryRemovals.isEmpty {
            let n = registryRemovals.count
            parts.append("takes \(n) \(n == 1 ? "entry" : "entries") off Claude Desktop's session list")
        }
        for edit in databaseEdits where !edit.isEmpty {
            let n = edit.rowCount
            guard n > 0 else {
                let bytes = edit.sizeBytes > 0 ? " (\(formatter.string(fromByteCount: edit.sizeBytes)))" : ""
                parts.append("takes it out of \(edit.database.lastPathComponent)\(bytes), keeping a copy of the whole database first")
                continue
            }
            let list = edit.listRemovals.isEmpty ? "" : " and takes it off \(agent.displayName)'s chat list"
            parts.append("deletes \(n) \(n == 1 ? "row" : "rows") (\(formatter.string(fromByteCount: edit.sizeBytes))) from \(edit.database.lastPathComponent)\(list), keeping a copy of the whole database first")
        }
        for removal in jsonRemovals {
            parts.append("takes it out of \(removal.file.lastPathComponent), keeping a copy first")
        }
        guard !parts.isEmpty || !commands.isEmpty else { return remarks.first ?? "Nothing to do." }
        let rest = parts.isEmpty ? "" : parts.joined(separator: " and ") + ". "
        let prefix = commandText.isEmpty ? "" : commandText + " "
        let undo = acknowledgement == nil ? "You can undo this." : "You can undo this only until \(agent.displayName) changes its files again."
        return prefix + rest.prefix(1).uppercased() + rest.dropFirst() + undo
    }

    /// The quarantine sentence is required wording: the user must know the plaintext stays.
    private var redactionSummary: String {
        guard !redactions.isEmpty else {
            return "Nothing can be redacted safely here, so nothing will change."
        }
        let n = redactionCount, files = redactions.count
        let what = "Replaces \(n) possible \(n == 1 ? "secret" : "secrets") in \(files) \(files == 1 ? "file" : "files") with [REDACTED:<rule>]."
        let kept = files == 1
            ? "The original, with the secrets, is kept in Domovy's quarantine so you can undo. Remove it with Purge originals."
            : "The originals, with the secrets, are kept in Domovy's quarantine so you can undo. Remove them with Purge originals."
        return what + " " + kept
    }
}

/// One file a redaction rewrites. Positions and masked previews only, never the values.
public struct FileRedaction: Hashable, Codable, Sendable {
    public struct Replacement: Hashable, Codable, Sendable {
        public let ruleID: String
        /// Byte range of the value within its line.
        public let range: Range<Int>
        public let preview: String

        public init(ruleID: String, range: Range<Int>, preview: String) {
            self.ruleID = ruleID
            self.range = range
            self.preview = preview
        }
    }

    public struct LineEdit: Hashable, Codable, Sendable {
        /// One-based line number.
        public let line: Int
        public let offset: Int64
        public let length: Int
        /// Sorted by position.
        public let replacements: [Replacement]

        public init(line: Int, offset: Int64, length: Int, replacements: [Replacement]) {
            self.line = line
            self.offset = offset
            self.length = length
            self.replacements = replacements
        }
    }

    public let file: URL
    public let sizeBytes: Int64
    /// Modification time at scan time. The executor refuses a file that changed since.
    public let modificationTime: FileTime?
    /// Archived (APFS-compressed) files are compressed again after the rewrite.
    public let wasCompressed: Bool
    public let lines: [LineEdit]
    public let note: String
    /// A shared index file (`history.jsonl`) the agent keeps appending to: only the planned
    /// lines are checked and rewritten, and undo puts back only those lines.
    public let isLineLevel: Bool

    public init(file: URL, sizeBytes: Int64, modificationTime: FileTime?, wasCompressed: Bool, lines: [LineEdit], note: String, isLineLevel: Bool = false) {
        self.file = file
        self.sizeBytes = sizeBytes
        self.modificationTime = modificationTime
        self.wasCompressed = wasCompressed
        self.lines = lines
        self.note = note
        self.isLineLevel = isLineLevel
    }

    public var replacementCount: Int { lines.reduce(0) { $0 + $1.replacements.count } }
}

/// A finding a redaction leaves as it is, and why.
public struct SkippedSecret: Hashable, Codable, Sendable {
    public let file: URL
    public let line: Int
    public let ruleID: String
    public let preview: String
    public let reason: String

    public init(file: URL, line: Int, ruleID: String, preview: String, reason: String) {
        self.file = file
        self.line = line
        self.ruleID = ruleID
        self.preview = preview
        self.reason = reason
    }
}
