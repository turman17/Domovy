import Foundation

/// Disk use of one agent, split into categories the user can act on.
public struct Footprint: Hashable, Codable, Sendable {
    /// What happens if the user removes a category.
    public enum Disposition: String, Codable, Sendable, CaseIterable {
        /// Safe to remove; the agent recreates it or never needs it again.
        case safe
        /// Removable, but the user loses something (history, resumable sessions).
        case consequences
        /// Needed for the agent to run. Domovy never removes it.
        case keep

        public var displayName: String {
            switch self {
            case .safe: "Safe to remove"
            case .consequences: "Consequences"
            case .keep: "Keep"
            }
        }
    }

    /// How the user deals with a category. Read-only guidance; nothing here runs on its own.
    public enum Guidance: Hashable, Codable, Sendable {
        /// Handled one session at a time in the Sessions list.
        case manageInSessions
        /// Steps the user takes in the agent itself.
        case instructions(String)
        /// Domovy's orphan cleanup plan (Disk screen, `domo orphans`).
        case cleanUpOrphans
        /// A guided cleanup plan (Disk screen, `domo clean <id>`).
        case cleanup(CleanupID)
    }

    public struct Category: Identifiable, Hashable, Codable, Sendable {
        public let name: String
        /// The folder to reveal in Finder.
        public let url: URL
        /// What the size covers, when that is not simply `url` (several files, a part of a folder).
        public let items: [URL]
        /// Bytes allocated on disk. Sparse and compressed files count what they really use.
        public let sizeBytes: Int64
        /// Sum of file lengths, for the tooltip.
        public let logicalBytes: Int64
        public let disposition: Disposition
        /// One line explaining the disposition.
        public let note: String
        public let guidance: Guidance?

        public var id: String { name }

        /// The guided cleanup for this row, if it has one. Keep rows never have one.
        public var cleanupID: CleanupID? {
            if case .cleanup(let id) = guidance, disposition != .keep { return id }
            return nil
        }

        public init(
            name: String,
            url: URL,
            items: [URL] = [],
            sizeBytes: Int64,
            logicalBytes: Int64? = nil,
            disposition: Disposition,
            note: String,
            guidance: Guidance? = nil
        ) {
            self.name = name
            self.url = url
            self.items = items
            self.sizeBytes = sizeBytes
            self.logicalBytes = logicalBytes ?? sizeBytes
            self.disposition = disposition
            self.note = note
            self.guidance = guidance
        }

        /// What Finder should select: a handful of covered items, or else the folder itself.
        public var revealURLs: [URL] { items.isEmpty || items.count > 50 ? [url] : items }
    }

    public let agent: AgentKind
    public let root: URL
    public let categories: [Category]

    public init(agent: AgentKind, root: URL, categories: [Category]) {
        self.agent = agent
        self.root = root
        self.categories = categories
    }

    public var totalBytes: Int64 {
        categories.reduce(0) { $0 + $1.sizeBytes }
    }

    public func bytes(_ disposition: Disposition) -> Int64 {
        categories.filter { $0.disposition == disposition }.reduce(0) { $0 + $1.sizeBytes }
    }
}

/// Anything that can report an agent's disk use: the session adapters, plus agents Domovy
/// only measures so far (Claude Desktop, Cursor).
public protocol FootprintProvider: Sendable {
    var kind: AgentKind { get }
    /// Throws `AdapterError.notInstalled` when the agent's folders are missing.
    func footprint() async throws -> Footprint
}
