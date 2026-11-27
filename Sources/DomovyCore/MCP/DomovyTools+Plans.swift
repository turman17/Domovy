import CryptoKit
import Foundation

/// Plans, plan tokens, execution and undo.
extension DomovyTools {
    /// Most items listed per plan; the counts and sizes always cover all of them.
    static let listedItems = 100

    func planDelete(_ arguments: [String: JSONValue]) async throws -> ToolOutcome {
        let destination: Destination
        switch arguments["destination"]?.stringValue {
        case nil: destination = context.settings.deleteDestination
        case "trash": destination = .trash
        case "quarantine": destination = .quarantine
        case let other?: throw ToolArgumentError(message: "Unknown destination \(other). Use trash or quarantine.")
        }
        return try await plan(arguments, action: .delete, destination: destination)
    }

    func planArchive(_ arguments: [String: JSONValue]) async throws -> ToolOutcome {
        try await plan(arguments, action: .archive, destination: nil)
    }

    private func plan(_ arguments: [String: JSONValue], action: Plan.Action, destination: Destination?) async throws -> ToolOutcome {
        try await plan(sessionIDs: try Self.sessionIDs(arguments), action: action, destination: destination)
    }

    /// Plans every requested session; sessions that cannot be planned are reported, not fatal.
    /// A token is issued only when at least one plan can run. `domo rm` and `domo archive` use
    /// this directly (`forCLI`: the text names the plan digest instead of the token), so the CLI
    /// plans and refuses exactly like the MCP tools.
    public func plan(sessionIDs ids: [String], action: Plan.Action, destination: Destination?, forCLI: Bool = false) async throws -> ToolOutcome {
        let resolved = try await resolve(ids)
        let herdr = context.herdrState()
        var results: [JSONValue] = []
        var lines: [String] = []
        var runnable: [(session: Session, plan: Plan)] = []
        var blocked: [JSONValue] = []

        for problem in resolved.problems {
            blocked.append(["session_id": .string(problem.id), "reason": .string(problem.reason)])
            lines.append("\(problem.id): \(problem.reason)")
        }
        for (adapter, sessions) in resolved.byAdapter {
            let planned = action == .delete
                ? await adapter.deletePlans(for: sessions, destination: destination ?? .trash)
                : await adapter.archivePlans(for: sessions)
            for item in planned {
                let session = item.session
                switch item.result {
                case .failure(let error):
                    blocked.append(["session_id": .string(session.id), "reason": .string(error.localizedDescription)])
                    lines.append("\(session.id): \(error.localizedDescription)")
                case .success(let planned):
                    let plan = herdr.markingLive(planned, for: session)
                    let refusal = refusal(for: session, plan: plan)
                    results.append(planJSON(plan, session: session, refusal: refusal))
                    lines.append(planText(plan, session: session, refusal: refusal))
                    if let refusal {
                        blocked.append(["session_id": .string(session.id), "reason": .string(refusal)])
                    } else if !plan.isEmpty {
                        runnable.append((session, plan))
                    }
                }
            }
        }

        var structured: [String: JSONValue] = [
            "action": .string(action.rawValue),
            "plans": .array(results),
            "blocked": .array(blocked),
        ]
        if let destination { structured["destination"] = .string(destination.rawValue) }
        guard !runnable.isEmpty else {
            lines.append("\nNothing can be \(action == .delete ? "deleted" : "archived") from this request" + (forCLI ? "." : ", so no plan token was issued."))
            return ToolOutcome(text: lines.joined(separator: "\n"), structured: .object(structured))
        }
        pruneTokens()
        let token = UUID().uuidString.lowercased()
        tokens[token] = PlanTicket(
            action: action,
            destination: destination,
            sessions: runnable.map { ($0.session.agent, $0.session.id) },
            fingerprints: Dictionary(runnable.map { ($0.session.id, Self.fingerprint($0.plan)) }, uniquingKeysWith: { first, _ in first }),
            createdAt: now()
        )
        let bytes = runnable.reduce(Int64(0)) { $0 + $1.plan.totalBytes }
        let expires = now().addingTimeInterval(tokenLifetime)
        structured["plan_token"] = .string(token)
        structured["expires_at"] = .string(Self.iso(expires))
        structured["runnable_count"] = .int(runnable.count)
        structured["total_bytes"] = .int(Int(bytes))
        let needsAck = runnable.contains { $0.plan.acknowledgement != nil }
        structured["needs_acknowledgement"] = .bool(needsAck)
        let digest = Self.digest(runnable.map { ($0.session.id, Self.fingerprint($0.plan)) })
        structured["plan_digest"] = .string(digest)
        let tool = action == .delete ? "delete_sessions" : "archive_sessions"
        if forCLI {
            lines.append("\nTotal: \(runnable.count) \(runnable.count == 1 ? "session" : "sessions"), \(Self.bytes(bytes)). Plan digest \(digest).\(needsAck ? " One or more plans need an OK that undo may stop working (--accept-limited-undo)." : "")")
            return ToolOutcome(text: lines.joined(separator: "\n"), structured: .object(structured))
        }
        lines.append("""

        Total: \(runnable.count) \(runnable.count == 1 ? "session" : "sessions"), \(Self.bytes(bytes)). \
        plan_token \(token) is valid for \(Int(tokenLifetime / 60)) minutes. Show this plan to the user; \
        call \(tool) with the token only after they agree.\(needsAck ? " One or more plans have an acknowledgement the user must accept (accept_limited_undo)." : "")
        """)
        return ToolOutcome(text: lines.joined(separator: "\n"), structured: .object(structured))
    }

    /// Carries out the plan behind a token: plans again, checks again, then runs all or nothing.
    func execute(_ arguments: [String: JSONValue], action: Plan.Action) async throws -> ToolOutcome {
        guard let token = arguments["plan_token"]?.stringValue?.lowercased(), !token.isEmpty else {
            throw ToolArgumentError(message: "plan_token is required. Call plan_\(action.rawValue) first and show the plan to the user.")
        }
        guard let ticket = tokens[token] else {
            return .failure("Unknown plan_token: it was never issued by this Domovy server, or it was already used. Nothing was changed. Call plan_\(action.rawValue) again.")
        }
        // One use only, whatever happens next.
        tokens[token] = nil
        guard ticket.action == action else {
            return .failure("This plan_token is for \(ticket.action.rawValue), not \(action.rawValue). Nothing was changed, and the token is used up: call plan_\(action.rawValue) and show that plan to the user.")
        }
        guard now().timeIntervalSince(ticket.createdAt) <= tokenLifetime else {
            return .failure("This plan is more than \(Int(tokenLifetime / 60)) minutes old, so Domovy did not run it. Nothing was changed. Plan again and show the new plan to the user.")
        }
        return try await execute(ticket, action: action, acceptLimitedUndo: arguments["accept_limited_undo"]?.boolValue ?? false)
    }

    /// Carries out the plan behind a token from `plan(sessionIDs:action:destination:)`, with the
    /// same checks as `delete_sessions` / `archive_sessions`.
    public func execute(token: String, action: Plan.Action, acceptLimitedUndo: Bool) async throws -> ToolOutcome {
        try await execute(["plan_token": .string(token), "accept_limited_undo": .bool(acceptLimitedUndo)], action: action)
    }

    private func execute(_ ticket: PlanTicket, action: Plan.Action, acceptLimitedUndo accept: Bool) async throws -> ToolOutcome {
        let resolved = try await resolve(ticket.sessions.map(\.id), agents: ticket.sessions.map(\.agent))
        var problems = resolved.problems.map { "\($0.id): \($0.reason)" }
        var plans: [Plan] = []
        let herdr = context.herdrState()
        for (adapter, sessions) in resolved.byAdapter {
            let planned = action == .delete
                ? await adapter.deletePlans(for: sessions, destination: ticket.destination ?? .trash)
                : await adapter.archivePlans(for: sessions)
            for item in planned {
                switch item.result {
                case .failure(let error):
                    problems.append("\(item.session.id): \(error.localizedDescription)")
                case .success(let planned):
                    var plan = herdr.markingLive(planned, for: item.session)
                    if let refusal = refusal(for: item.session, plan: plan) {
                        problems.append("\(item.session.id): \(refusal)")
                    } else if Self.fingerprint(plan) != ticket.fingerprints[item.session.id] {
                        problems.append("\(item.session.id): the plan changed since the user saw it (files were added or removed).")
                    } else if let text = plan.acknowledgement, !accept {
                        problems.append("\(item.session.id): needs the user's explicit OK: \(text) Pass accept_limited_undo only if they accepted it.")
                    } else if !plan.isEmpty {
                        plan.isAcknowledged = plan.acknowledgement != nil && accept
                        plans.append(plan)
                    }
                }
            }
        }
        guard problems.isEmpty else {
            return ToolOutcome(
                text: "Nothing was changed.\n" + problems.joined(separator: "\n") + "\nPlan again and show the new plan to the user.",
                structured: ["changed": false, "problems": .array(problems.map { .string($0) })],
                isError: true
            )
        }
        guard !plans.isEmpty else {
            return ToolOutcome(text: "Nothing to do: these sessions have nothing left to \(action.rawValue).", structured: ["changed": false])
        }
        let entries: [UndoEntry]
        do {
            entries = try context.executor.execute(plans)
        } catch {
            let partial = (try? context.executor.undoLog.entries())?.filter { entry in plans.contains { $0.id == entry.planID } } ?? []
            let undo = partial.first.map { " Some changes were made; undo them with undo_id \(($0.batchID ?? $0.id).uuidString.lowercased())." } ?? " Nothing was changed."
            return ToolOutcome(text: error.localizedDescription + undo, structured: [
                "changed": .bool(!partial.isEmpty),
                "error": .string(error.localizedDescription),
                "undo_id": partial.first.map { .string(($0.batchID ?? $0.id).uuidString.lowercased()) } ?? .null,
            ], isError: true)
        }
        if action == .delete {
            await TranscriptSearchIndex.forget(plans.map { (agent: $0.agent, id: $0.sessionID) }, storeRoot: context.executor.storeRoot)
        }
        let undoID = (entries.first?.batchID ?? entries.first?.id)?.uuidString.lowercased() ?? ""
        let moved = entries.reduce(0) { $0 + $1.moved.count }
        let compressed = entries.reduce(0) { $0 + $1.compressed.count }
        let bytes = plans.reduce(Int64(0)) { $0 + $1.totalBytes }
        let notes = entries.flatMap(\.notes)
        let leftovers = entries.flatMap(\.leftovers)
        let sessionCount = Set(entries.map(\.sessionID)).count
        let sessions = "\(sessionCount) \(sessionCount == 1 ? "session" : "sessions")"
        let what = action == .delete
            ? "Moved \(moved) \(moved == 1 ? "item" : "items") (\(Self.bytes(bytes))) to \((ticket.destination ?? .trash).displayName) for \(sessions)"
            : "Archived \(sessions) (\(compressed) \(compressed == 1 ? "file" : "files") compressed)"
        var text = "Done. \(what). Undo with undo_id \(undoID)."
        if !notes.isEmpty { text += "\n" + notes.joined(separator: "\n") }
        if !leftovers.isEmpty { text += "\nChecked afterwards; left behind:\n" + leftovers.map { "- \($0)" }.joined(separator: "\n") }
        return ToolOutcome(text: text, structured: [
            "changed": true,
            "undo_id": .string(undoID),
            "sessions": .array(entries.map { .string($0.sessionID) }),
            "moved_items": .int(moved),
            "compressed_files": .int(compressed),
            "total_bytes": .int(Int(bytes)),
            "notes": .array(notes.map { .string($0) }),
            "leftovers": .array(leftovers.map { .string($0) }),
        ])
    }

    func undo(_ arguments: [String: JSONValue]) throws -> ToolOutcome {
        let wanted = (arguments["undo_id"]?.stringValue ?? "last").lowercased()
        let executor = context.executor
        let undone: [UndoEntry]
        if wanted == "last" || wanted.isEmpty {
            undone = try executor.undoLatestBatch()
        } else {
            guard wanted.count >= 8 else { throw ToolArgumentError(message: "undo_id must be the id a delete or archive returned, or \"last\".") }
            let matching = try executor.undoLog.entries().filter { entry in
                entry.id.uuidString.lowercased().hasPrefix(wanted) || entry.batchID?.uuidString.lowercased().hasPrefix(wanted) == true
            }
            guard !matching.isEmpty else { return .failure("No undo entry \(wanted). Nothing was changed.") }
            let pending = matching.filter { !$0.isUndone }.sorted { $0.createdAt > $1.createdAt }
            guard !pending.isEmpty else { return .failure("That action was already undone.") }
            undone = try pending.map { try executor.undo($0) }
        }
        let text = "Undone: " + undone.map { "\($0.action.rawValue) of \($0.agent.displayName) session \($0.sessionID)" }.joined(separator: "; ") + "."
        return ToolOutcome(text: text, structured: [
            "undone": .array(undone.map { ["session_id": .string($0.sessionID), "agent": .string($0.agent.displayName), "action": .string($0.action.rawValue)] }),
        ])
    }

    // MARK: Helpers

    /// Why a session must not be touched now, or `nil`.
    func refusal(for session: Session, plan: Plan) -> String? {
        if session.status == .live || plan.liveCheck.isLive {
            let reasons = plan.liveCheck.reasons.joined(separator: " ")
            return "This session is live, so Domovy will not touch it." + (reasons.isEmpty ? "" : " " + reasons)
        }
        let age = now().timeIntervalSince(session.lastActive)
        if age < recentActivityWindow {
            return "This session was written to \(Int(max(age, 0) / 60)) minutes ago and may be the one in use right now (possibly your own), so Domovy will not touch it."
        }
        return nil
    }

    /// Requested ids resolved to sessions, grouped by adapter in adapter order. Ids may be unique
    /// prefixes of at least 8 characters.
    func resolve(_ ids: [String], agents: [AgentKind]? = nil) async throws -> (byAdapter: [(any AgentAdapter, [Session])], problems: [(id: String, reason: String)]) {
        let all = try await allSessions()
        var chosen: [String: (adapter: any AgentAdapter, session: Session)] = [:]
        var order: [String] = []
        var problems: [(id: String, reason: String)] = []
        for (index, id) in ids.enumerated() {
            let wanted = id.lowercased()
            let agent = agents?[index]
            let candidates = all.filter { agent == nil || $0.session.agent == agent }
            let exact = candidates.filter { $0.session.id.lowercased() == wanted }
            let matches = exact.isEmpty && wanted.count >= 8 ? candidates.filter { $0.session.id.lowercased().hasPrefix(wanted) } : exact
            guard matches.count == 1, let match = matches.first else {
                problems.append((id, matches.isEmpty ? "No session with this id was found." : "This prefix matches \(matches.count) sessions; use the full id."))
                continue
            }
            let key = "\(match.session.agent.rawValue)/\(match.session.id)"
            if chosen[key] == nil { order.append(key) }
            chosen[key] = match
        }
        var grouped: [(any AgentAdapter, [Session])] = []
        for adapter in context.adapters {
            let sessions = order.compactMap { chosen[$0] }.filter { $0.adapter.kind == adapter.kind }.map(\.session)
            if !sessions.isEmpty { grouped.append((adapter, sessions)) }
        }
        return (grouped, problems)
    }

    static func sessionIDs(_ arguments: [String: JSONValue]) throws -> [String] {
        guard let list = arguments["session_ids"]?.arrayValue, !list.isEmpty else {
            throw ToolArgumentError(message: "session_ids must be a non-empty list of ids from list_sessions.")
        }
        let ids = list.compactMap(\.stringValue).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard ids.count == list.count, ids.count <= 200 else {
            throw ToolArgumentError(message: "session_ids must be 1 to 200 id strings.")
        }
        return ids
    }

    func pruneTokens() {
        let cutoff = now().addingTimeInterval(-tokenLifetime)
        tokens = tokens.filter { $0.value.createdAt >= cutoff }
    }

    /// A short stable id for what a set of plans changes. `domo rm|archive -y --if-plan` runs
    /// only when planning again gives the same digest as the dry run the user saw.
    static func digest(_ fingerprints: [(id: String, fingerprint: String)]) -> String {
        let text = fingerprints.map { "\($0.id)\n\($0.fingerprint)" }.sorted().joined(separator: "\n\n")
        return SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Everything a plan changes, by path, so a plan that grew or shrank since is noticed.
    static func fingerprint(_ plan: Plan) -> String {
        var parts = plan.moves.map { "m:" + $0.source.path }
        parts += plan.indexEdits.map { "i:\($0.file.path):\($0.matchValue)" }
        parts += plan.registryRemovals.map { "r:" + $0.file.path }
        parts += plan.compressions.map { "c:" + $0.file.path }
        parts += plan.relocations.map { "a:\($0.source.path):\($0.target.path)" }
        parts += plan.commands.map { "x:" + $0.commandLine }
        parts += plan.databaseEdits.map { "d:\($0.database.path):\($0.rowCount)" }
        parts += plan.jsonRemovals.map { "j:\($0.file.path):\($0.key)" }
        return parts.sorted().joined(separator: "\n")
    }

    func planJSON(_ plan: Plan, session: Session, refusal: String?) -> JSONValue {
        let home = context.home
        func listed<T>(_ items: [T], _ map: (T) -> JSONValue) -> JSONValue { .array(items.prefix(Self.listedItems).map(map)) }
        var item: [String: JSONValue] = [
            "session_id": .string(session.id),
            "agent": .string(SessionAgent.id(of: session.agent)),
            "title": .string(Self.safeTitle(session)),
            "summary": .string(plan.summary),
            "total_bytes": .int(Int(plan.totalBytes)),
            "total_size": .string(Self.bytes(plan.totalBytes)),
            "empty": .bool(plan.isEmpty),
            "moves_count": .int(plan.moves.count),
            "moves": listed(plan.moves) { ["path": .string(Self.display($0.source, home: home)), "size_bytes": .int(Int($0.sizeBytes)), "note": .string($0.note)] },
            "index_edits": listed(plan.indexEdits) { ["file": .string(Self.display($0.file, home: home)), "lines": .int($0.lineNumbers.count), "note": .string($0.note)] },
            "registry_removals": listed(plan.registryRemovals) { ["file": .string(Self.display($0.file, home: home)), "note": .string($0.note)] },
            "database_edits": listed(plan.databaseEdits.filter { !$0.isEmpty }) { ["database": .string(Self.display($0.database, home: home)), "rows": .int($0.rowCount)] },
            "json_removals": listed(plan.jsonRemovals) { ["file": .string(Self.display($0.file, home: home)), "note": .string($0.note)] },
            "compressions_count": .int(plan.compressions.count),
            "compressions": listed(plan.compressions) { ["path": .string(Self.display($0.file, home: home)), "size_bytes": .int(Int($0.sizeBytes)), "estimated_bytes_after": .int(Int($0.estimatedBytes))] },
            "archive_moves": listed(plan.relocations) { ["path": .string(Self.display($0.source, home: home)), "to": .string(Self.display($0.target, home: home)), "size_bytes": .int(Int($0.sizeBytes))] },
            "commands": .array(plan.commands.map { ["command": .string($0.commandLine), "note": .string($0.note)] }),
            "remarks": .array(plan.remarks.map { .string($0) }),
            "live_check": [
                "is_live": .bool(plan.liveCheck.isLive),
                "reasons": .array(plan.liveCheck.reasons.map { .string($0) }),
                "checked": .array(plan.liveCheck.checkedSignals.map { .string($0) }),
                "open_handles": .string(plan.liveCheck.openHandles.rawValue),
            ],
            "apps_that_must_be_quit": .array(plan.mustNotBeRunning.map { .string($0.appName) }),
        ]
        if let destination = plan.destination { item["destination"] = .string(destination.rawValue) }
        if let ack = plan.acknowledgement { item["acknowledgement"] = .string(ack) }
        if let refusal { item["refused"] = .string(refusal) }
        return .object(item)
    }

    func planText(_ plan: Plan, session: Session, refusal: String?) -> String {
        let home = context.home
        var lines = ["\(session.agent.displayName) session \(session.id) \u{201C}\(Self.safeTitle(session))\u{201D}"]
        if let refusal {
            lines.append("  Refused: \(refusal)")
            return lines.joined(separator: "\n")
        }
        lines.append("  " + plan.summary)
        for command in plan.commands { lines.append("  run: \(command.commandLine)") }
        for move in plan.moves.prefix(20) { lines.append("  move: \(Self.display(move.source, home: home)) (\(Self.bytes(move.sizeBytes)))") }
        if plan.moves.count > 20 { lines.append("  \u{2026} and \(plan.moves.count - 20) more items") }
        for edit in plan.indexEdits { lines.append("  edit: remove \(edit.lineNumbers.count) lines from \(Self.display(edit.file, home: home))") }
        for removal in plan.registryRemovals { lines.append("  remove entry: \(Self.display(removal.file, home: home))") }
        for edit in plan.databaseEdits where !edit.isEmpty { lines.append("  database: delete \(edit.rowCount) rows from \(Self.display(edit.database, home: home)) (backed up first)") }
        for item in plan.relocations.prefix(20) { lines.append("  archive: \(Self.display(item.source, home: home)) \u{2192} \(Self.display(item.target, home: home))") }
        for item in plan.compressions.prefix(20) { lines.append("  compress: \(Self.display(item.file, home: home)) (\(Self.bytes(item.sizeBytes)))") }
        if plan.compressions.count > 20 { lines.append("  \u{2026} and \(plan.compressions.count - 20) more files") }
        for remark in plan.remarks { lines.append("  note: \(remark)") }
        if let ack = plan.acknowledgement { lines.append("  needs OK: \(ack)") }
        if !plan.mustNotBeRunning.isEmpty { lines.append("  quit first: \(plan.mustNotBeRunning.map(\.appName).joined(separator: ", "))") }
        lines.append("  live check: not live (checked \(plan.liveCheck.checkedSignals.joined(separator: ", ")))")
        return lines.joined(separator: "\n")
    }
}
