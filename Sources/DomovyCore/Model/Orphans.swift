import Foundation

/// Something an agent left behind that no session owns any more, or a second copy of one.
public struct OrphanItem: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A uuid-keyed companion folder (or session-env file) whose transcript is gone.
        case companion
        /// A Claude Desktop registry entry whose transcript is gone.
        case desktopEntry
        /// An `.orphaned-*` or `.superseded-*` copy of a transcript that still exists.
        case duplicateCopy
        /// An earlier transcript of a Desktop conversation, re-stamped under a new id (#89592).
        case duplicateSession
        /// A second Desktop registry entry for the same transcript.
        case duplicateDesktopEntry
    }

    public let kind: Kind
    public let url: URL
    /// The session id the item is keyed by.
    public let sessionID: String
    /// Bytes on disk; for a duplicate session, every file of it.
    public let sizeBytes: Int64
    public let modified: Date?

    public var id: String { url.path }
}

/// One conversation with more than one copy: what stays and what can go.
public struct DuplicateGroup: Identifiable, Hashable, Sendable {
    /// The transcript id the copies belong to (the one Desktop points at, when it does).
    public let sessionID: String
    /// What stays: the newest copy, plus anything an index still points at.
    public let kept: [URL]
    public let extra: [OrphanItem]

    public var id: String { sessionID }
    public var extraBytes: Int64 { extra.reduce(0) { $0 + $1.sizeBytes } }
}

/// What to clean up: things nothing owns, or extra copies.
public enum OrphanScope: String, Codable, Sendable, CaseIterable {
    case orphans
    case duplicates
}

/// Orphans and duplicates of one Claude Code home, with Claude Desktop's registry.
/// Built from names, sizes, dates and registry fields; no transcript is opened.
public struct OrphanReport: Sendable {
    public let orphans: [OrphanItem]
    public let duplicates: [DuplicateGroup]
    /// Whether Domovy may change Claude Desktop's registry.
    public let desktopStatus: AdapterStatus

    public init(orphans: [OrphanItem], duplicates: [DuplicateGroup], desktopStatus: AdapterStatus) {
        self.orphans = orphans
        self.duplicates = duplicates
        self.desktopStatus = desktopStatus
    }

    public static let empty = OrphanReport(orphans: [], duplicates: [], desktopStatus: .notInstalled)

    public var isEmpty: Bool { orphans.isEmpty && duplicates.isEmpty }
    public var companions: [OrphanItem] { orphans.filter { $0.kind == .companion } }
    public var desktopEntries: [OrphanItem] { orphans.filter { $0.kind == .desktopEntry } }
    public var orphanBytes: Int64 { orphans.reduce(0) { $0 + $1.sizeBytes } }
    public var duplicateItems: [OrphanItem] { duplicates.flatMap(\.extra) }
    public var duplicateBytes: Int64 { duplicates.reduce(0) { $0 + $1.extraBytes } }

    /// "2 companion folders and 1 Desktop entry whose transcript is gone."
    public var orphanSummary: String {
        var parts: [String] = []
        let c = companions.count, d = desktopEntries.count
        if c > 0 { parts.append("\(c) companion \(c == 1 ? "folder" : "folders")") }
        if d > 0 { parts.append("\(d) Claude Desktop \(d == 1 ? "entry" : "entries")") }
        guard !parts.isEmpty else { return "Nothing left behind: every companion folder and Desktop entry has its transcript." }
        return parts.joined(separator: " and ") + " whose transcript is gone."
    }

    /// "3 extra copies of 2 conversations. The newest copy of each stays."
    public var duplicateSummary: String {
        let n = duplicateItems.count, g = duplicates.count
        guard n > 0 else { return "No duplicate transcripts or Desktop entries." }
        return "\(n) extra \(n == 1 ? "copy" : "copies") of \(g) \(g == 1 ? "conversation" : "conversations"). The newest copy of each stays."
    }
}
