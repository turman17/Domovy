import Foundation

/// `search_sessions`: which sessions talk about something. It returns ids, titles, agents,
/// dates and how many messages match, never snippets or any other transcript text: what an
/// agent's model reads leaves the Mac.
extension DomovyTools {
    static let searchDefinition = ToolDefinition(
        name: "search_sessions",
        title: "Search inside transcripts",
        description: """
        Finds sessions whose conversation mentions the query, best match first, using Domovy's \
        local full-text index (built or updated on the call). Words match any word they start; \
        text in double quotes is a phrase. Returns id, agent, title (the first prompt, secrets \
        masked), last active and the number of matching messages only: never transcript text \
        or snippets. Use the ids with list_sessions, plan_delete or plan_archive.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "query": ["type": "string", "minLength": 1, "description": "Words to find; \"double quotes\" for a phrase."],
                "agent": ["type": "string", "enum": .array(agentIDs.map { .string($0) }), "description": "Only this agent."],
                "limit": ["type": "integer", "minimum": 1, "maximum": 200, "default": 20, "description": "At most this many sessions (default 20)."],
            ],
            "required": ["query"],
            "additionalProperties": false,
        ],
        annotations: .readOnly
    )

    func searchSessions(_ arguments: [String: JSONValue]) async throws -> ToolOutcome {
        guard let query = arguments["query"]?.stringValue, !SearchQuery(query).isEmpty else {
            throw ToolArgumentError(message: "query needs at least one word.")
        }
        var agent: AgentKind?
        if let text = arguments["agent"]?.stringValue {
            guard let kind = SessionAgent.parse(text) else {
                throw ToolArgumentError(message: "Unknown agent \(text). Use one of: \(Self.agentIDs.joined(separator: ", ")).")
            }
            agent = kind
        }
        let limit = min(max(arguments["limit"]?.intValue ?? 20, 1), 200)
        let searcher = TranscriptSearcher(context: context)
        let results = try await searcher.search(query, agent: agent, limit: limit, index: try searcher.openIndex())
        let rows: [JSONValue] = results.map { result in
            [
                "id": .string(result.session.id),
                "agent": .string(SessionAgent.id(of: result.session.agent)),
                "agent_name": .string(result.session.agentLabel),
                "title": .string(Self.safeTitle(result.session)),
                "last_active": .string(Self.iso(result.session.lastActive)),
                "match_count": .int(result.hit.matchCount),
            ]
        }
        var lines = results.map { result in
            let s = result.session
            return "\(s.id)  \(s.agentLabel)  \(Self.relative(s.lastActive, now: now()))  \(result.hit.matchCount) matching \(result.hit.matchCount == 1 ? "message" : "messages")  \(Self.safeTitle(s))"
        }
        lines.insert(results.isEmpty
            ? "No session mentions that."
            : "\(results.count) \(results.count == 1 ? "session matches" : "sessions match"), best first (titles only; Domovy never returns transcript text):", at: 0)
        return ToolOutcome(text: lines.joined(separator: "\n"), structured: ["sessions": .array(rows)])
    }
}
