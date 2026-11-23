import Foundation

/// Whether an adapter understands the storage it found.
public enum AdapterStatus: Hashable, Codable, Sendable {
    /// The agent's folder is not present at this root.
    case notInstalled
    /// Layout recognised; listing and planning are allowed.
    case ready
    /// Something about the layout is unknown. Listing may work; plans are refused.
    case readOnly(reason: String)

    public var canMutate: Bool { self == .ready }
}

/// Errors every adapter may throw. Messages are written for the user.
public enum AdapterError: Error, LocalizedError, Hashable, Sendable {
    case notInstalled(AgentKind)
    case readOnly(AgentKind, reason: String)
    case sessionNotFound(String)
    case notImplemented(AgentKind, feature: String)
    case protectedPathInPlan(URL)
    case unreadable(URL, reason: String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let agent):
            "\(agent.displayName) is not installed at this location."
        case .readOnly(let agent, let reason):
            "\(agent.displayName) is read-only: \(reason)"
        case .sessionNotFound(let id):
            "No session with id \(id) was found."
        case .notImplemented(let agent, let feature):
            "\(feature.capitalized) is not available yet for \(agent.displayName)."
        case .protectedPathInPlan(let url):
            "Refusing to plan a change to \(url.lastPathComponent): the agent needs it to run."
        case .unreadable(let url, let reason):
            "Could not read \(url.lastPathComponent): \(reason)"
        }
    }
}

/// One adapter per agent. Adapters take an injected root and never assume `~`.
public protocol AgentAdapter: FootprintProvider {
    var kind: AgentKind { get }
    /// The agent's config directory (e.g. `<home>/.claude`).
    var root: URL { get }

    /// Checks the layout. Call before planning; a `.readOnly` adapter never mutates.
    func status() async -> AdapterStatus
    func sessions() async throws -> [Session]
    func artifacts(of session: Session) async throws -> [Artifact]
    func liveCheck(_ session: Session) async throws -> LiveCheckResult
    func deletePlan(for session: Session, destination: Destination) async throws -> Plan
    func archivePlan(for session: Session) async throws -> Plan
    /// The first `limit` messages of the conversation, for display only. Values of `findings`
    /// in the transcript are replaced by their masked previews before anything is parsed.
    func transcript(of session: Session, limit: Int, masking findings: [SecretFinding]) async throws -> Transcript
}

extension AgentAdapter {
    /// The first `limit` messages, unmasked.
    public func transcript(of session: Session, limit: Int) async throws -> Transcript {
        try await transcript(of: session, limit: limit, masking: [])
    }

    /// Delete plan with the default, reversible destination.
    public func deletePlan(for session: Session) async throws -> Plan {
        try await deletePlan(for: session, destination: .trash)
    }

    /// Finds a session by exact id or unique id prefix.
    public func session(matching idOrPrefix: String) async throws -> Session {
        let all = try await sessions()
        if let exact = all.first(where: { $0.id == idOrPrefix }) { return exact }
        let candidates = all.filter { $0.id.hasPrefix(idOrPrefix) }
        guard candidates.count == 1, let match = candidates.first else {
            throw AdapterError.sessionNotFound(idOrPrefix)
        }
        return match
    }
}
