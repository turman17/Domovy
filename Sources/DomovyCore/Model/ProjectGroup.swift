import Foundation

/// The sessions of every agent that worked in one project folder.
public struct ProjectGroup: Identifiable, Hashable, Sendable {
    /// The project folder; `nil` for sessions whose agent recorded none.
    public let path: String?
    /// Newest first.
    public let sessions: [Session]

    /// `sessions` are kept in the order given; `group(_:)` sorts them newest first.
    public init(path: String?, sessions: [Session]) {
        self.path = path
        self.sessions = sessions
    }

    public var id: String { path ?? "" }
    /// Folder name, or "No project".
    public var name: String {
        path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No project"
    }
    public var sizeBytes: Int64 { sessions.reduce(0) { $0 + $1.sizeBytes } }
    public var lastActive: Date { sessions.lazy.map(\.lastActive).max() ?? .distantPast }
    /// Agents in this project, most sessions first.
    public var agents: [AgentKind] {
        var counts: [AgentKind: Int] = [:]
        for session in sessions { counts[session.agent, default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }.map(\.key)
    }

    /// Tokens of the sessions that record them, and how many of them do.
    public func tokens(in usage: [Session.ID: TokenUsageResult]) -> (usage: TokenUsage, counted: Int) {
        var total = TokenUsage()
        var counted = 0
        for session in sessions {
            guard let found = usage[session.id]?.usage else { continue }
            total = total + found
            counted += 1
        }
        return (total, counted)
    }

    /// One group per project folder, most recently active first; sessions without a project
    /// come last. Paths are compared standardized, so `/a/b/` and `/a/b` are one project.
    public static func group(_ sessions: [Session]) -> [ProjectGroup] {
        var order: [String?] = []
        var members: [String?: [Session]] = [:]
        for session in sessions.sorted(by: { $0.lastActive > $1.lastActive }) {
            let key = session.projectPath.map(normalize).flatMap { $0.isEmpty ? nil : $0 }
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(session)
        }
        let groups = order.map { ProjectGroup(path: $0, sessions: members[$0] ?? []) }
        return groups.filter { $0.path != nil } + groups.filter { $0.path == nil }
    }

    static func normalize(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { return trimmed }
        let standardized = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        return standardized.count > 1 && standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }
}
