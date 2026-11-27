import Foundation

/// The read-only tools: sessions, disk use, processes.
extension DomovyTools {
    /// Every session of every installed agent, with the adapter that owns it.
    func allSessions() async throws -> [(adapter: any AgentAdapter, session: Session)] {
        try await context.allSessions()
    }

    func listSessions(_ arguments: [String: JSONValue]) async throws -> ToolOutcome {
        var all = try await allSessions().map(\.session)
        if let text = arguments["agent"]?.stringValue {
            guard let kind = SessionAgent.parse(text) else {
                throw ToolArgumentError(message: "Unknown agent \(text). Use one of: \(Self.agentIDs.joined(separator: ", ")).")
            }
            all = all.filter { $0.agent == kind }
        }
        if let project = arguments["project"]?.stringValue?.lowercased(), !project.isEmpty {
            all = all.filter { ($0.projectPath ?? "").lowercased().contains(project) }
        }
        if let text = arguments["status"]?.stringValue {
            guard let status = Session.Status(rawValue: text) else {
                throw ToolArgumentError(message: "Unknown status \(text). Use live, idle, archived or expiring.")
            }
            all = all.filter { $0.status == status || (status == .archived && $0.isArchived) }
        }
        if let days = arguments["older_than_days"]?.doubleValue {
            let cutoff = now().addingTimeInterval(-days * 86_400)
            all = all.filter { $0.lastActive < cutoff }
        }
        if let value = arguments["min_size"] {
            guard let bytes = Self.parseSize(value) else {
                throw ToolArgumentError(message: "min_size must be a number of bytes or text like \"50 MB\".")
            }
            all = all.filter { $0.sizeBytes >= bytes }
        }
        if let query = arguments["query"]?.stringValue?.lowercased(), !query.isEmpty {
            all = all.filter {
                $0.id.lowercased().contains(query) || $0.displayTitle.lowercased().contains(query)
                    || ($0.projectPath ?? "").lowercased().contains(query)
            }
        }
        all.sort { $0.lastActive > $1.lastActive }
        let limit = min(max(arguments["limit"]?.intValue ?? 50, 1), 500)
        let shown = Array(all.prefix(limit))
        let total = all.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let includeTokens = arguments["include_tokens"]?.boolValue ?? false
        let usage = includeTokens ? await context.tokenUsageStore.usage(for: shown, adapters: context.adapters) : [:]

        let rows: [JSONValue] = shown.map { session in
            var row: [String: JSONValue] = [
                "id": .string(session.id),
                "agent": .string(SessionAgent.id(of: session.agent)),
                "agent_name": .string(session.agentLabel),
                "title": .string(Self.safeTitle(session)),
                "last_active": .string(Self.iso(session.lastActive)),
                "last_active_relative": .string(Self.relative(session.lastActive, now: now())),
                "size_bytes": .int(Int(session.sizeBytes)),
                "size": .string(Self.bytes(session.sizeBytes)),
                "status": .string(session.status.rawValue),
                "archived": .bool(session.isArchived),
            ]
            if session.agent.isExperimental { row["agent_experimental"] = .bool(true) }
            if let project = session.projectPath { row["project"] = .string(project) }
            if let expires = session.expiresAt { row["expires_at"] = .string(Self.iso(expires)) }
            if let note = session.retentionNote { row["retention_note"] = .string(note) }
            if includeTokens, let found = usage[session.id]?.usage { row.merge(Self.tokenFields(found)) { _, new in new } }
            return .object(row)
        }
        var lines = shown.map { s in
            "\(s.id)  \(s.agentLabel)  \(s.projectName ?? "-")  \(Self.relative(s.lastActive, now: now()))  \(Self.bytes(s.sizeBytes))  \(s.status.rawValue)  \(Self.safeTitle(s))"
        }
        let head = all.isEmpty
            ? "No sessions match. All tidy."
            : "\(all.count) \(all.count == 1 ? "session" : "sessions") (\(Self.bytes(total)))" + (shown.count < all.count ? ", showing the newest \(shown.count)" : "") + ":"
        lines.insert(head, at: 0)
        let experimental = Set(shown.map(\.agent).filter(\.isExperimental))
        if !experimental.isEmpty {
            let names = experimental.map(\.displayName).sorted().joined(separator: ", ")
            lines.append("\(names): \(AgentKind.experimentalNote)")
        }
        return ToolOutcome(text: lines.joined(separator: "\n"), structured: [
            "sessions": .array(rows),
            "total_count": .int(all.count),
            "total_size_bytes": .int(Int(total)),
            "truncated": .bool(shown.count < all.count),
        ])
    }

    func diskUsage() async -> ToolOutcome {
        let result = await FootprintScanner.scan(context.footprintProviders)
        var lines: [String] = []
        let agents: [JSONValue] = result.footprints.map { footprint in
            lines.append("\(footprint.agent.displayName): \(Self.bytes(footprint.totalBytes)) (safe to remove: \(Self.bytes(footprint.bytes(.safe))))")
            let categories: [JSONValue] = footprint.categories.sorted { $0.sizeBytes > $1.sizeBytes }.map { category in
                lines.append("  \(Self.bytes(category.sizeBytes))  \(category.disposition.rawValue)  \(category.name): \(category.note)")
                var item: [String: JSONValue] = [
                    "name": .string(category.name),
                    "size_bytes": .int(Int(category.sizeBytes)),
                    "size": .string(Self.bytes(category.sizeBytes)),
                    "disposition": .string(category.disposition.rawValue),
                    "note": .string(category.note),
                    "path": .string(Self.display(category.url, home: context.home)),
                ]
                if let id = category.cleanupID { item["cleanup_id"] = .string(id.rawValue) }
                return .object(item)
            }
            return [
                "agent": .string(footprint.agent.displayName),
                "experimental": .bool(footprint.agent.isExperimental),
                "root": .string(Self.display(footprint.root, home: context.home)),
                "total_bytes": .int(Int(footprint.totalBytes)),
                "safe_bytes": .int(Int(footprint.bytes(.safe))),
                "consequences_bytes": .int(Int(footprint.bytes(.consequences))),
                "keep_bytes": .int(Int(footprint.bytes(.keep))),
                "categories": .array(categories),
            ]
        }
        let total = result.footprints.reduce(Int64(0)) { $0 + $1.totalBytes }
        lines.insert(result.footprints.isEmpty ? "No agent folders found. All tidy." : "Agents use \(Self.bytes(total)) in all.", at: 0)
        if !result.footprints.isEmpty {
            lines.append("Guided cleanups (cleanup_id) run from the Domovy app or `domo clean <id> --dry-run`.")
        }
        return ToolOutcome(text: lines.joined(separator: "\n"), structured: [
            "agents": .array(agents),
            "total_bytes": .int(Int(total)),
            "failures": .array(result.failures.map { .string($0) }),
        ])
    }

    func listProcesses(_ arguments: [String: JSONValue]) async -> ToolOutcome {
        let watcher = ProcessWatcher(sessions: ProcessSessionResolver(home: context.home))
        guard let report = await watcher.sampled(over: 1) else {
            return .failure("Could not read the process list.")
        }
        let orphansOnly = arguments["orphans_only"]?.boolValue ?? false
        func node(_ n: ProcessNode) -> JSONValue {
            var item: [String: JSONValue] = [
                "pid": .int(Int(n.pid)),
                "name": .string(n.name),
                "kind": .string(n.kind.displayName),
                "frozen": .bool(n.isFrozen),
                "orphan": .bool(n.isOrphan),
                "total_memory_bytes": .int(Int(n.totalBytes)),
                "process_count": .int(n.subtree.count),
            ]
            if let agent = n.agent { item["agent"] = .string(agent.displayName) }
            if let cpu = n.totalCPUPercent { item["cpu_percent"] = .double((cpu * 10).rounded() / 10) }
            return .object(item)
        }
        var lines: [String] = []
        let groups: [JSONValue] = orphansOnly ? [] : report.groups.map { group in
            lines.append("\(group.root.pid)  \(group.agent.displayName)  \(group.root.name)  \(Self.bytes(group.root.totalBytes)) memory, \(group.root.subtree.count) processes")
            var item = node(group.root).objectValue ?? [:]
            item["session_ids"] = .array(group.sessionIDs.map { .string($0) })
            return .object(item)
        }
        let orphans = report.orphans.map { orphan in
            lines.append("orphan \(orphan.pid)  \(orphan.agent?.displayName ?? "unknown")  \(orphan.name)  \(Self.bytes(orphan.totalBytes))")
            return node(orphan)
        }
        lines.insert("\(report.processCount) agent processes, \(Self.bytes(report.totalBytes)) memory, \(report.orphanCount) orphaned.", at: 0)
        if report.orphanCount > 0 { lines.append("Quit or freeze processes from the Domovy app or `domo quit <pid>`; this server does not signal processes.") }
        return ToolOutcome(text: lines.joined(separator: "\n"), structured: [
            "groups": .array(groups),
            "orphans": .array(orphans),
            "total_memory_bytes": .int(Int(report.totalBytes)),
        ])
    }

    /// `tokens` (input without cache, output, cache reads and writes, total), `models` and,
    /// where a model is priced, `estimated_cost_usd` with its `cost_source`.
    static func tokenFields(_ usage: TokenUsage) -> [String: JSONValue] {
        let totals = usage.totals
        var fields: [String: JSONValue] = [
            "tokens": .object([
                "input": .int(Int(totals.input)),
                "output": .int(Int(totals.output)),
                "cache_read": .int(Int(totals.cacheRead)),
                "cache_write": .int(Int(totals.cacheWrite)),
                "total": .int(Int(totals.total)),
            ]),
            "models": .array(usage.models.map { .string($0) }),
        ]
        if let cost = usage.cost {
            fields["estimated_cost_usd"] = .double((cost.usd * 10_000).rounded() / 10_000)
            fields["cost_source"] = .string(cost.source == .agent ? "agent" : "estimate, list prices as of \(PriceTable.asOf)")
        }
        return fields
    }

    // MARK: Formatting

    /// The cleaned first prompt, one line, at most 120 characters, with anything that looks
    /// like a secret replaced by its masked preview.
    static func safeTitle(_ session: Session) -> String {
        var title = session.displayTitle.replacingOccurrences(of: "\n", with: " ")
        let data = Data(title.utf8)
        let matches = SecretMatcher().matches(in: data)
        if !matches.isEmpty {
            var bytes = [UInt8](data)
            for match in matches.reversed() {
                bytes.replaceSubrange(match.range, with: Array("[\(match.preview)]".utf8))
            }
            title = String(decoding: bytes, as: UTF8.self)
        }
        return title.count > 120 ? String(title.prefix(119)) + "\u{2026}" : title
    }

    static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: count)
    }

    static func iso(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// A path with the home folder shown as `~`.
    public static func display(_ url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.path, base = home.standardizedFileURL.path
        return path.hasPrefix(base + "/") ? "~" + path.dropFirst(base.count) : path
    }

    /// Bytes, or text like "50 MB", "1.5GB", "200k", and sizes as Domovy prints them
    /// ("526 bytes", "1,2 MB" in locales with a decimal comma).
    static func parseSize(_ value: JSONValue) -> Int64? {
        if let number = value.doubleValue { return number >= 0 ? Int64(number) : nil }
        guard let text = value.stringValue?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        let digits = text.prefix { $0.isNumber || $0 == "." || $0 == "," }
        guard let number = Double(digits.replacingOccurrences(of: ",", with: ".")), number >= 0 else { return nil }
        let unit = text.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        let factors: [String: Double] = ["": 1, "b": 1, "byte": 1, "bytes": 1, "k": 1e3, "kb": 1e3, "m": 1e6, "mb": 1e6, "g": 1e9, "gb": 1e9, "t": 1e12, "tb": 1e12,
                                         "kib": 1_024, "mib": 1_048_576, "gib": 1_073_741_824]
        guard let factor = factors[unit] else { return nil }
        return Int64(number * factor)
    }
}
