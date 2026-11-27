import Foundation

/// One agent's part of a session scan.
public struct AgentSessionScan: Sendable {
    public let adapter: any AgentAdapter
    public let status: AdapterStatus
    public let sessions: [Session]
    /// Why listing failed, if it did.
    public let error: (any Error)?
}

extension DomovyContext {
    /// Lists every installed agent's sessions once. Aider has no index and looks for its files
    /// in the other agents' project folders: it gets them from this scan instead of listing
    /// every agent a second time. Results are in adapter order; agents not installed are left out.
    public func scanSessions() async -> [AgentSessionScan] {
        let aider = adapters.compactMap { $0 as? AiderAdapter }
        let others = adapters.filter { !($0 is AiderAdapter) }
        let scanningOthers = Task {
            await withTaskGroup(of: (Int, AgentSessionScan?).self) { group in
                for (index, adapter) in others.enumerated() {
                    group.addTask { (index, await Self.scan(adapter)) }
                }
                var results: [(Int, AgentSessionScan?)] = []
                for await result in group { results.append(result) }
                return results.sorted { $0.0 < $1.0 }.compactMap(\.1)
            }
        }
        let projectPaths = Task { await scanningOthers.value.flatMap { $0.sessions.compactMap(\.projectPath) } }
        for adapter in aider { adapter.useKnownProjects(projectPaths) }
        var results = await scanningOthers.value
        for adapter in aider {
            if let scan = await Self.scan(adapter) { results.append(scan) }
        }
        return results
    }

    /// Every session of every installed agent, newest first. Throws the first listing error.
    public func allSessions() async throws -> [(adapter: any AgentAdapter, session: Session)] {
        let scans = await scanSessions()
        if let error = scans.lazy.compactMap(\.error).first { throw error }
        return scans.flatMap { scan in scan.sessions.map { (scan.adapter, $0) } }
            .sorted { $0.session.lastActive > $1.session.lastActive }
    }

    /// Token usage cached in Domovy's folder under this home.
    public var tokenUsageStore: TokenUsageStore {
        TokenUsageStore(storeRoot: Self.storeRoot(home: home))
    }

    private static func scan(_ adapter: any AgentAdapter) async -> AgentSessionScan? {
        let status = await adapter.status()
        guard status != .notInstalled else { return nil }
        do {
            return AgentSessionScan(adapter: adapter, status: status, sessions: try await adapter.sessions(), error: nil)
        } catch {
            return AgentSessionScan(adapter: adapter, status: status, sessions: [], error: error)
        }
    }
}
