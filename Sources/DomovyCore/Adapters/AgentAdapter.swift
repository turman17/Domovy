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
    case unsafeID(AgentKind, id: String)

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
        case .unsafeID(let agent, let id):
            "Refusing to change this \(agent.displayName) session: its id (\(id.prefix(40))) has characters Domovy does not put into a path or a command."
        }
    }
}

/// One adapter per agent. Adapters take an injected root and never assume `~`.
/// One session of a batch and its plan, or why it could not be planned.
public struct PlannedSession: Sendable {
    public let session: Session
    public let result: Result<Plan, any Error>

    public init(session: Session, result: Result<Plan, any Error>) {
        self.session = session
        self.result = result
    }

    public var plan: Plan? { try? result.get() }
}

public protocol AgentAdapter: FootprintProvider {
    var kind: AgentKind { get }
    /// The agent's config directory (e.g. `<home>/.claude`).
    var root: URL { get }
    /// Every folder a plan of this adapter may change; the executor refuses a path outside them.
    /// `[root]` unless the agent keeps data in more than one place.
    var scope: [URL] { get }

    /// Checks the layout. Call before planning; a `.readOnly` adapter never mutates.
    func status() async -> AdapterStatus
    func sessions() async throws -> [Session]
    func artifacts(of session: Session) async throws -> [Artifact]
    func liveCheck(_ session: Session) async throws -> LiveCheckResult
    func deletePlan(for session: Session, destination: Destination) async throws -> Plan
    /// Delete plans for several sessions of this agent, in order. One session that cannot be
    /// planned does not stop the others; its error is in its result.
    func deletePlans(for sessions: [Session], destination: Destination) async -> [PlannedSession]
    func archivePlan(for session: Session) async throws -> Plan
    /// Archive plans for several sessions of this agent, in order, like `deletePlans`.
    func archivePlans(for sessions: [Session]) async -> [PlannedSession]
    /// Live checks for several sessions of this agent, in order, each what `liveCheck` would
    /// answer. Adapters override it to read shared files and ask the open-file question once.
    func liveChecks(for sessions: [Session]) async -> [Result<LiveCheckResult, any Error>]
    /// The first `limit` messages of the conversation, for display only. Values of `findings`
    /// in the transcript are replaced by their masked previews before anything is parsed.
    func transcript(of session: Session, limit: Int, masking findings: [SecretFinding]) async throws -> Transcript
    /// The newest `limit` messages before `cursor` (`nil`: the end of the conversation), for a
    /// reader that opens at the newest message and loads older pages as it scrolls up.
    func transcriptPage(of session: Session, limit: Int, before cursor: TranscriptCursor?, masking findings: [SecretFinding]) async throws -> Transcript
}

extension AgentAdapter {
    public var scope: [URL] { [root] }

    /// The first `limit` messages, unmasked.
    public func transcript(of session: Session, limit: Int) async throws -> Transcript {
        try await transcript(of: session, limit: limit, masking: [])
    }

    /// Messages kept by the default `transcriptPage`, for agents whose transcripts are not
    /// line-based files that can be read from the end.
    static var pagedReadLimit: Int { 5_000 }

    /// Pages cut from the first messages the adapter reads. Its own byte budget still applies:
    /// when that cuts the conversation, `isTruncated` says the newest messages were not reached.
    public func transcriptPage(of session: Session, limit: Int, before cursor: TranscriptCursor?, masking findings: [SecretFinding]) async throws -> Transcript {
        let all = try await transcript(of: session, limit: Self.pagedReadLimit, masking: findings)
        let end = min(cursor.map { Int(max(0, $0.position)) } ?? all.messages.count, all.messages.count)
        let start = max(0, end - max(0, limit))
        return Transcript(
            messages: Array(all.messages[start..<end]),
            isTruncated: cursor == nil && all.isTruncated,
            hiddenLineCount: cursor == nil ? all.hiddenLineCount : 0,
            olderCursor: start > 0 ? TranscriptCursor(Int64(start)) : nil
        )
    }

    /// One plan at a time. Adapters whose plans read shared files override this to read them
    /// once per batch.
    public func deletePlans(for sessions: [Session], destination: Destination) async -> [PlannedSession] {
        var planned: [PlannedSession] = []
        for session in sessions {
            do {
                planned.append(PlannedSession(session: session, result: .success(try await deletePlan(for: session, destination: destination))))
            } catch {
                planned.append(PlannedSession(session: session, result: .failure(error)))
            }
        }
        return planned
    }

    /// One plan at a time, like the default `deletePlans`.
    public func archivePlans(for sessions: [Session]) async -> [PlannedSession] {
        var planned: [PlannedSession] = []
        for session in sessions {
            do {
                planned.append(PlannedSession(session: session, result: .success(try await archivePlan(for: session))))
            } catch {
                planned.append(PlannedSession(session: session, result: .failure(error)))
            }
        }
        return planned
    }

    /// One check at a time.
    public func liveChecks(for sessions: [Session]) async -> [Result<LiveCheckResult, any Error>] {
        var results: [Result<LiveCheckResult, any Error>] = []
        for session in sessions {
            do {
                results.append(.success(try await liveCheck(session)))
            } catch {
                results.append(.failure(error))
            }
        }
        return results
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
