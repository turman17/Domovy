import Foundation

/// Disk use of one agent, split into categories the user can act on.
public struct Footprint: Hashable, Codable, Sendable {
    /// What happens if the user removes a category.
    public enum Disposition: String, Codable, Sendable {
        /// Safe to remove; the agent recreates it or never needs it again.
        case safe
        /// Removable, but the user loses something (history, resumable sessions).
        case consequences
        /// Needed for the agent to run. Domovy never removes it.
        case keep
    }

    public struct Category: Hashable, Codable, Sendable {
        public let name: String
        public let url: URL
        public let sizeBytes: Int64
        public let disposition: Disposition
        /// One line explaining the disposition.
        public let note: String

        public init(name: String, url: URL, sizeBytes: Int64, disposition: Disposition, note: String) {
            self.name = name
            self.url = url
            self.sizeBytes = sizeBytes
            self.disposition = disposition
            self.note = note
        }
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
}
