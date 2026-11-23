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

/// Exact description of a mutating action, computed before anything changes.
/// The same value drives the UI preview, `domo rm --dry-run` and the executor.
public struct Plan: Identifiable, Hashable, Codable, Sendable {
    public enum Action: String, Codable, Sendable {
        case delete
        case archive
    }

    public let id: UUID
    public let createdAt: Date
    public let agent: AgentKind
    public let sessionID: String
    public let action: Action
    public let destination: Destination
    public let moves: [FileMove]
    public let indexEdits: [IndexEdit]
    public let liveCheck: LiveCheckResult

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        agent: AgentKind,
        sessionID: String,
        action: Action,
        destination: Destination,
        moves: [FileMove],
        indexEdits: [IndexEdit],
        liveCheck: LiveCheckResult
    ) {
        self.id = id
        self.createdAt = createdAt
        self.agent = agent
        self.sessionID = sessionID
        self.action = action
        self.destination = destination
        self.moves = moves
        self.indexEdits = indexEdits
        self.liveCheck = liveCheck
    }

    public var totalBytes: Int64 {
        moves.reduce(0) { $0 + $1.sizeBytes } + indexEdits.reduce(0) { $0 + $1.removedBytes }
    }

    public var isEmpty: Bool {
        moves.isEmpty && indexEdits.isEmpty
    }

    /// Plain-language summary in the Domovy voice: say exactly what happens.
    public var summary: String {
        if liveCheck.isLive {
            return "This session is live, so nothing will change. " + liveCheck.reasons.joined(separator: " ")
        }
        var parts: [String] = []
        if !moves.isEmpty {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            formatter.allowsNonnumericFormatting = false
            let bytes = formatter.string(fromByteCount: moves.reduce(0) { $0 + $1.sizeBytes })
            parts.append("Moves \(moves.count) \(moves.count == 1 ? "item" : "items") (\(bytes)) to \(destination.displayName)")
        }
        for edit in indexEdits {
            let n = edit.lineNumbers.count
            parts.append("removes \(n) \(n == 1 ? "line" : "lines") from \(edit.file.lastPathComponent)")
        }
        guard !parts.isEmpty else { return "Nothing to do." }
        return parts.joined(separator: " and ") + ". You can undo this."
    }
}
