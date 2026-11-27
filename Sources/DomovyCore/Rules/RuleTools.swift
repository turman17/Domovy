import Foundation

/// The rules' MCP tools: read-only. No tool enables, changes or runs a rule; that stays with
/// the user in the app or `domo rules`.
extension DomovyTools {
    static let ruleDefinitions: [ToolDefinition] = [
        ToolDefinition(
            name: "list_rules",
            title: "List cleanup rules",
            description: """
            Lists Domovy's cleanup rules: id, the rule in plain words, whether it is on, whether \
            it asks before running, and its last run. Read-only; rules are turned on and run only \
            by the user in the Domovy app or `domo rules`.
            """,
            inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
            annotations: .readOnly
        ),
        ToolDefinition(
            name: "plan_rules",
            title: "Dry-run cleanup rules",
            description: """
            Computes, without changing anything, what the cleanup rules would do right now: each \
            session they would archive or move to the Trash, with sizes, and every session left \
            alone with the reason (live, recently active, read-only agent). Read-only; it issues \
            no plan token and nothing can execute it.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "rule_ids": ["type": "array", "items": ["type": "string"], "description": "Only these rules (ids from list_rules). Default: the rules that are on."],
                    "include_disabled": ["type": "boolean", "default": false, "description": "Also plan rules that are off."],
                ],
                "additionalProperties": false,
            ],
            annotations: .readOnly
        ),
    ]

    func listRules() throws -> ToolOutcome {
        let runner = RuleRunner(context: context, now: now)
        let rules = try runner.store.rules()
        let history = (try? runner.store.history()) ?? []
        var lines: [String] = []
        let items: [JSONValue] = rules.map { rule in
            let last = history.first { $0.ruleIDs.contains(rule.id) }
            lines.append("\(rule.isEnabled ? "on " : "off") \(rule.id.uuidString.lowercased().prefix(8))  \(rule.title)\(rule.askBeforeRunning ? " (asks first)" : "")")
            var item: [String: JSONValue] = [
                "id": .string(rule.id.uuidString.lowercased()),
                "title": .string(rule.title),
                "sentence": .string(rule.sentence),
                "enabled": .bool(rule.isEnabled),
                "ask_before_running": .bool(rule.askBeforeRunning),
                "action": .string(rule.action.rawValue),
                "agents": .array(rule.scope.agents.map { .string(RuleAgentID.id(of: $0)) }),
            ]
            if let last {
                item["last_run"] = .string(Self.iso(last.startedAt))
                item["last_run_summary"] = .string(last.summary)
            }
            return .object(item)
        }
        if lines.isEmpty { lines.append("No rules.") }
        return ToolOutcome(text: lines.joined(separator: "\n"), structured: ["rules": .array(items)])
    }

    func planRules(_ arguments: [String: JSONValue]) async throws -> ToolOutcome {
        let runner = RuleRunner(context: context, now: now)
        var rules = try runner.store.rules()
        if let ids = arguments["rule_ids"]?.arrayValue {
            let wanted = ids.compactMap(\.stringValue).map { $0.lowercased() }
            rules = rules.filter { rule in wanted.contains { rule.id.uuidString.lowercased().hasPrefix($0) && $0.count >= 8 } }
            guard !rules.isEmpty else { throw ToolArgumentError(message: "No rule matches those ids. Use ids from list_rules.") }
        } else if arguments["include_disabled"]?.boolValue != true {
            rules = rules.filter(\.isEnabled)
        }
        guard !rules.isEmpty else {
            return ToolOutcome(text: "No rule is on, so nothing would run. Pass include_disabled to plan them anyway.", structured: ["matches": [], "skipped": []])
        }
        let preview = await runner.preview(rules)
        var lines = [preview.summary]
        for match in preview.matches.prefix(Self.listedItems) {
            lines.append("- \(match.session.id) \(match.session.agent.displayName), \(Self.bytes(match.plan.totalBytes)): \(match.rule.title)")
        }
        for skip in preview.skipped.prefix(Self.listedItems) {
            lines.append("left alone: \(skip.sessionID ?? skip.agent.displayName): \(skip.reason)")
        }
        lines += preview.notes
        lines.append("Dry run: nothing was changed. Only the user can run rules, in Domovy or with `domo rules run`.")
        return ToolOutcome(text: lines.joined(separator: "\n"), structured: [
            "summary": .string(preview.summary),
            "total_bytes": .int(Int(preview.totalBytes)),
            "matches": .array(preview.matches.prefix(Self.listedItems).map { match in
                [
                    "session_id": .string(match.session.id),
                    "agent": .string(RuleAgentID.id(of: match.session.agent)),
                    "title": .string(Self.safeTitle(match.session)),
                    "rule_id": .string(match.rule.id.uuidString.lowercased()),
                    "action": .string(match.rule.action.rawValue),
                    "bytes": .int(Int(match.plan.totalBytes)),
                ]
            }),
            "match_count": .int(preview.matches.count),
            "skipped": .array(preview.skipped.prefix(Self.listedItems).map { skip in
                [
                    "agent": .string(RuleAgentID.id(of: skip.agent)),
                    "session_id": skip.sessionID.map { .string($0) } ?? .null,
                    "reason": .string(skip.reason),
                ]
            }),
            "notes": .array(preview.notes.map { .string($0) }),
        ])
    }
}
