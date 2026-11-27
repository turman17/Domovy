import Foundation

/// The tools `domo mcp` offers. Reads are free; every change goes through a plan the user saw:
/// `plan_delete` / `plan_archive` return a short-lived `plan_token`, and only that token makes
/// `delete_sessions` / `archive_sessions` act. Results carry titles, ids, sizes and paths of
/// the agents' own files, never transcript content.
public actor DomovyTools {
    let context: DomovyContext
    let now: @Sendable () -> Date
    /// How long a plan token stays valid.
    let tokenLifetime: TimeInterval
    /// A session written to this recently is treated as possibly in use (it is often the very
    /// session of the agent calling Domovy) and is never deleted or archived.
    let recentActivityWindow: TimeInterval
    var tokens: [String: PlanTicket] = [:]

    public init(
        context: DomovyContext,
        tokenLifetime: TimeInterval = 600,
        recentActivityWindow: TimeInterval = 600,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.context = context
        self.tokenLifetime = tokenLifetime
        self.recentActivityWindow = recentActivityWindow
        self.now = now
    }

    /// Runs one tool. Tool failures come back as an error outcome the model can read.
    public func call(_ name: String, arguments: [String: JSONValue]) async -> ToolOutcome {
        // Every schema says additionalProperties: false; a misspelt filter must not silently widen a list.
        if let known = Self.definitions.first(where: { $0.name == name })?.inputSchema["properties"]?.objectValue {
            let unknown = arguments.keys.filter { known[$0] == nil }.sorted()
            if !unknown.isEmpty {
                let allowed = known.keys.sorted().joined(separator: ", ")
                return .failure("Unknown argument\(unknown.count == 1 ? "" : "s") for \(name): \(unknown.joined(separator: ", ")). \(allowed.isEmpty ? "It takes no arguments." : "It takes: \(allowed).")")
            }
        }
        do {
            switch name {
            case "list_sessions": return try await listSessions(arguments)
            case "search_sessions": return try await searchSessions(arguments)
            case "disk_usage": return await diskUsage()
            case "list_processes": return await listProcesses(arguments)
            case "plan_delete": return try await planDelete(arguments)
            case "plan_archive": return try await planArchive(arguments)
            case "delete_sessions": return try await execute(arguments, action: .delete)
            case "archive_sessions": return try await execute(arguments, action: .archive)
            case "undo": return try undo(arguments)
            case "list_rules": return try listRules()
            case "plan_rules": return try await planRules(arguments)
            default: return .failure("Unknown tool: \(name)")
            }
        } catch let error as ToolArgumentError {
            return .failure(error.message)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: Definitions

    static let instructions = """
    Domovy lists and tidies the sessions AI coding agents leave on this Mac (Claude Code, Codex, \
    Gemini CLI, Antigravity, OpenCode, Copilot CLI, Cursor). Read freely with list_sessions and \
    disk_usage; search_sessions finds sessions by what was said in them (ids and titles only). To change anything: call plan_delete or plan_archive, show the user the plan \
    (what moves where, sizes, remarks), and call delete_sessions or archive_sessions with the \
    plan_token only after the user agrees. Nothing is deleted permanently: files go to the Trash \
    or Domovy's quarantine, and undo puts them back. Live sessions, including the one you are \
    running in, are always refused. Prefer archive for recent work.
    """

    static let agentIDs = SessionAgent.allCases.map(SessionAgent.id(of:))

    static let definitions: [ToolDefinition] = sessionDefinitions + [searchDefinition] + ruleDefinitions

    static let sessionDefinitions: [ToolDefinition] = [
        ToolDefinition(
            name: "list_sessions",
            title: "List agent sessions",
            description: """
            Lists AI agent sessions on this Mac, newest first: id, agent, title (the first prompt, \
            shortened, with secrets masked), project, last active, size and status \
            (live, idle, archived, expiring). Never returns transcript content. Use the ids with \
            plan_delete or plan_archive.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "agent": ["type": "string", "enum": .array(agentIDs.map { .string($0) }), "description": "Only this agent."],
                    "project": ["type": "string", "description": "Only sessions whose project path contains this text (case-insensitive)."],
                    "status": ["type": "string", "enum": ["live", "idle", "archived", "expiring"], "description": "Only sessions with this status."],
                    "older_than_days": ["type": "number", "minimum": 0, "description": "Only sessions last active more than this many days ago."],
                    "min_size": ["type": ["string", "integer"], "description": "Only sessions at least this big: bytes, or text like \"50 MB\"."],
                    "query": ["type": "string", "description": "Only sessions whose title, id or project contains this text."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 500, "default": 50, "description": "At most this many sessions (default 50)."],
                    "include_tokens": ["type": "boolean", "default": false, "description": "Add token counts, model ids and an estimated cost for sessions whose agent records usage. Slower the first time: it reads the transcripts' usage records (never their text)."],
                ],
                "additionalProperties": false,
            ],
            annotations: .readOnly
        ),
        ToolDefinition(
            name: "disk_usage",
            title: "Agent disk usage",
            description: """
            Disk use per agent, split into categories marked safe (the agent recreates it), \
            consequences (removable, but something is lost) or keep (the agent needs it), each \
            with a one-line note. Read-only.
            """,
            inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
            annotations: .readOnly
        ),
        ToolDefinition(
            name: "list_processes",
            title: "Agent processes",
            description: """
            Running agent processes: each agent's process tree with memory and CPU, the sessions \
            it serves, and orphans (processes whose agent is gone). Process names only, never \
            command lines. Read-only; takes about a second to sample CPU.
            """,
            inputSchema: [
                "type": "object",
                "properties": ["orphans_only": ["type": "boolean", "default": false, "description": "Only orphaned processes."]],
                "additionalProperties": false,
            ],
            annotations: .readOnly
        ),
        ToolDefinition(
            name: "plan_delete",
            title: "Plan a delete",
            description: """
            Computes, without changing anything, exactly what deleting these sessions would do: \
            every file that moves to the Trash or Domovy's quarantine, index lines and database \
            rows removed, sizes, the live-session check and remarks. Returns a plan_token valid \
            for 10 minutes. Show the plan to the user and pass the token to delete_sessions only \
            after they agree.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "session_ids": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 200,
                                    "description": "Session ids from list_sessions (a unique prefix of 8+ characters works)."],
                    "destination": ["type": "string", "enum": ["trash", "quarantine"],
                                    "description": "Where removed files go. Both are undoable. Without it, the default from Domovy's settings (the Trash unless changed)."],
                ],
                "required": ["session_ids"],
                "additionalProperties": false,
            ],
            annotations: .readOnly
        ),
        ToolDefinition(
            name: "plan_archive",
            title: "Plan an archive",
            description: """
            Computes, without changing anything, what archiving these sessions would do: Claude \
            Code and Gemini CLI files are compressed in place (the agent can still resume them), \
            Codex sessions go to archived_sessions through `codex archive`. Returns a plan_token \
            valid for 10 minutes. Show the plan to the user and pass the token to archive_sessions \
            only after they agree.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "session_ids": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 200,
                                    "description": "Session ids from list_sessions (a unique prefix of 8+ characters works)."],
                ],
                "required": ["session_ids"],
                "additionalProperties": false,
            ],
            annotations: .readOnly
        ),
        ToolDefinition(
            name: "delete_sessions",
            title: "Delete sessions (after the user agreed)",
            description: """
            Carries out a plan from plan_delete. Call only after showing that plan to the user and \
            getting a clear yes. Plans again and checks again that no session is live or changed; \
            refuses otherwise. Moves files to the Trash or quarantine (never a permanent delete) \
            and returns an undo_id for undo.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "plan_token": ["type": "string", "description": "The plan_token plan_delete returned."],
                    "accept_limited_undo": ["type": "boolean", "default": false,
                                            "description": "Set only when the plan has an acknowledgement and the user accepted it."],
                ],
                "required": ["plan_token"],
                "additionalProperties": false,
            ],
            annotations: .init(readOnly: false, destructive: true, idempotent: false)
        ),
        ToolDefinition(
            name: "archive_sessions",
            title: "Archive sessions (after the user agreed)",
            description: """
            Carries out a plan from plan_archive. Call only after showing that plan to the user and \
            getting a clear yes. Plans again and checks again that no session is live or changed; \
            refuses otherwise. Returns an undo_id for undo.
            """,
            inputSchema: [
                "type": "object",
                "properties": ["plan_token": ["type": "string", "description": "The plan_token plan_archive returned."]],
                "required": ["plan_token"],
                "additionalProperties": false,
            ],
            annotations: .init(readOnly: false, destructive: false, idempotent: false)
        ),
        ToolDefinition(
            name: "undo",
            title: "Undo a Domovy action",
            description: """
            Undoes a delete or archive: puts moved files back with their dates and restores index \
            lines, or decompresses. Pass the undo_id a delete or archive returned, or "last" for \
            the most recent action.
            """,
            inputSchema: [
                "type": "object",
                "properties": ["undo_id": ["type": "string", "default": "last", "description": "An undo_id, or \"last\"."]],
                "additionalProperties": false,
            ],
            annotations: .init(readOnly: false, destructive: true, idempotent: false)
        ),
    ]
}

/// The agents `list_sessions` can filter by, with stable lowercase ids for tools.
/// The agent ids the tools take and return, one per session agent of `AgentKind`, so every
/// agent Domovy lists can be filtered on: the case name in kebab case ("claude-code",
/// "gemini-code-assist"), with a few shorter names kept as they were first published.
enum SessionAgent {
    static let allCases: [AgentKind] = AgentKind.allCases.filter(\.hasSessions)

    private static let published: [AgentKind: String] = [.openCode: "opencode", .vsCodeChat: "vscode-chat", .continueDev: "continue"]

    static func id(of kind: AgentKind) -> String {
        if let id = published[kind] { return id }
        var id = ""
        for character in kind.rawValue {
            if character.isUppercase, !id.isEmpty { id.append("-") }
            id.append(contentsOf: character.lowercased())
        }
        return id
    }

    /// "claude-code", "Claude Code", "claudeCode" all match.
    static func parse(_ text: String) -> AgentKind? {
        let wanted = text.lowercased().filter { $0.isLetter || $0.isNumber }
        return allCases.first { kind in
            [id(of: kind), kind.rawValue, kind.displayName].contains { $0.lowercased().filter { $0.isLetter || $0.isNumber } == wanted }
        }
    }
}

/// A bad tool argument, with a message for the model.
struct ToolArgumentError: Error {
    let message: String
}

/// What a plan token stands for.
struct PlanTicket: Sendable {
    let action: Plan.Action
    let destination: Destination?
    let sessions: [(agent: AgentKind, id: String)]
    /// What each plan would change, by session id, to notice a plan that changed since.
    let fingerprints: [String: String]
    let createdAt: Date
}
