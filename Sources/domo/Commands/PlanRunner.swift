import ArgumentParser
import DomovyCore
import Foundation

/// Filters `ls`, `rm` and `archive` share.
struct SessionFilters: ParsableArguments {
    @Option(name: .long, help: "Only sessions last active longer ago than this (e.g. 30d, 2w, 12h).")
    var older: AgeThreshold?

    @Option(name: .long, help: "Only this agent (claude-code, codex, gemini, ...).")
    var agent: String?

    @Option(name: .long, help: "Only sessions whose project path contains this text.")
    var project: String?

    var isEmpty: Bool { older == nil && agent == nil && project == nil }

    func agentKind() throws -> AgentKind? {
        guard let agent else { return nil }
        guard let kind = RuleAgentID.parse(agent) else {
            throw ValidationError("Unknown agent \(agent). Use one of: \(RuleAgentID.all.joined(separator: ", ")).")
        }
        return kind
    }

    func matches(_ session: Session, agent kind: AgentKind?, now: Date = Date()) -> Bool {
        if let kind, session.agent != kind { return false }
        if let older, session.lastActive >= now.addingTimeInterval(-older.seconds) { return false }
        if let project = project?.lowercased(), !project.isEmpty, !(session.projectPath ?? "").lowercased().contains(project) { return false }
        return true
    }
}

/// Flags of a command that plans, then acts.
struct PlanFlags: ParsableArguments {
    @Flag(name: .long, help: "Print the plan and change nothing.")
    var dryRun = false

    @Flag(name: [.customShort("y"), .long], help: "Skip the confirmation prompt. Required when stdin is not a terminal.")
    var yes = false

    @Option(name: .long, help: "Act only if the plan is still the one a dry run printed (its plan digest).")
    var ifPlan: String?

    @Flag(name: .long, help: "Print the plan and the result as JSON, for scripts and agents.")
    var json = false
}

/// `domo rm` and `domo archive` run through Domovy's MCP tools in-process, so the CLI plans,
/// refuses (live, written to in the last 10 minutes, Herdr panes) and re-checks before running
/// exactly like an agent's `plan_delete` + `delete_sessions`.
enum PlanRunner {
    static func run(_ action: Plan.Action, sessionIDs: [String], destination: Destination?, flags: PlanFlags,
                    acceptLimitedUndo: Bool, options: RootOptions) async throws {
        guard !sessionIDs.isEmpty else {
            if flags.json {
                Self.printJSON(["dry_run": .bool(flags.dryRun), "plan": .null, "message": "No sessions match."])
            } else {
                print("No sessions match. Nothing to \(action == .delete ? "remove" : "archive").")
            }
            return
        }
        let tools = DomovyTools(context: options.context)
        let planned = try await tools.plan(sessionIDs: sessionIDs, action: action, destination: destination, forCLI: true)
        var plan = planned.structured.objectValue ?? [:]
        let token = plan["plan_token"]?.stringValue
        plan["plan_token"] = nil
        plan["expires_at"] = nil
        let digest = plan["plan_digest"]?.stringValue

        func finish(_ result: JSONValue?, text: String?) {
            if flags.json {
                var output: [String: JSONValue] = ["dry_run": .bool(flags.dryRun), "plan": .object(plan)]
                if let result { output["result"] = result }
                Self.printJSON(.object(output))
            } else if let text {
                print(text)
            }
        }

        if !flags.json { print(planned.text) }
        if flags.dryRun {
            finish(nil, text: "\nDry run: nothing was changed.")
            return
        }
        guard let token, let digest else {
            finish(["changed": false, "problems": plan["blocked"] ?? .array([])], text: "\nNothing was changed.")
            throw ExitCode.failure
        }
        if let wanted = flags.ifPlan?.lowercased(), wanted != digest {
            let problem = "The plan changed since the dry run (digest \(wanted), now \(digest)). Nothing was changed. Show the new plan and ask again."
            finish(["changed": false, "problems": [.string(problem)]], text: "\n" + problem)
            throw ExitCode.failure
        }
        let needsAck = plan["needs_acknowledgement"]?.boolValue ?? false
        var accept = acceptLimitedUndo
        if needsAck, flags.yes, !accept { throw DomoError.acknowledgementRequired }
        if !flags.yes {
            if flags.json { throw DomoError.confirmationRequired }
            let count = plan["runnable_count"]?.intValue ?? 0
            let bytes = Format.bytes(Int64(plan["total_bytes"]?.intValue ?? 0))
            let sessions = "\(count) \(count == 1 ? "session" : "sessions")"
            let question = action == .delete
                ? "Move \(sessions) (\(bytes)) to \((destination ?? .trash).displayName)?"
                : "Archive \(sessions) (\(bytes))?"
            try confirm("\n\(question)\(needsAck ? " Undo may stop working for some of them (see above). Continue anyway?" : "") You can undo this. [y/N] ")
            // A yes at the prompt is the explicit OK.
            accept = accept || needsAck
        }
        let result = try await tools.execute(token: token, action: action, acceptLimitedUndo: accept)
        var text = result.text
        if let undo = result.structured["undo_id"]?.stringValue {
            text = text.replacingOccurrences(of: "Undo with undo_id \(undo).", with: "Undo with `domo undo \(undo)`.")
        }
        finish(result.structured, text: "\n" + text)
        if result.isError { throw ExitCode.failure }
    }

    static func printJSON(_ value: JSONValue) {
        print(String(decoding: value.encoded(), as: UTF8.self))
    }
}

extension RootOptions {
    /// Full ids for what the user named: each id or unique prefix, or every session matching
    /// `filters` (never live ones), newest first.
    func sessionIDs(_ ids: [String], filters: SessionFilters, where include: (AgentSessionScan, Session) -> Bool = { _, _ in true }) async throws -> [String] {
        guard ids.isEmpty == false || !filters.isEmpty else {
            throw ValidationError("Name sessions by id, or select them with --older, --agent or --project.")
        }
        guard ids.isEmpty || filters.isEmpty else {
            throw ValidationError("Pass session ids or filters (--older, --agent, --project), not both.")
        }
        let scans = await scan()
        if !ids.isEmpty {
            return try ids.map { try Self.session(matching: $0, in: scans).session.id }
        }
        let kind = try filters.agentKind()
        var found: [Session] = []
        for scan in scans {
            if let error = scan.error { throw error }
            found += scan.sessions.filter { $0.status != .live && filters.matches($0, agent: kind) && include(scan, $0) }
        }
        return found.sorted { $0.lastActive > $1.lastActive }.map(\.id)
    }
}
