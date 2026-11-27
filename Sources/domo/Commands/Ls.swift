import ArgumentParser
import DomovyCore
import Foundation

struct Ls: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List agent sessions.")

    @OptionGroup var options: RootOptions

    @Flag(name: .long, help: "Print full session ids instead of the first 8 characters.")
    var full = false

    @Flag(name: .long, help: "Add token counts and an estimated cost, read from transcripts that record them (cached afterwards).")
    var tokens = false

    @OptionGroup var filters: SessionFilters

    @Option(name: .long, help: "Only sessions with this status: live, idle, archived or expiring.")
    var status: Session.Status?

    @Flag(name: .long, help: "Print sessions as JSON (the newest 500), for scripts and agents.")
    var json = false

    func run() async throws {
        let kind = try filters.agentKind()
        if json {
            try await printJSON(agent: kind)
            return
        }
        var sessions: [Session] = []
        let scans = await options.scan()
        for scan in scans {
            if case .readOnly(let reason) = scan.status {
                FileHandle.standardError.write(Data("note: \(scan.adapter.kind.displayName) is read-only: \(reason)\n".utf8))
            }
            if let error = scan.error { throw Domo.fail(error) }
            sessions += scan.sessions.filter { session in
                filters.matches(session, agent: kind) && status.map { session.status == $0 || ($0 == .archived && session.isArchived) } ?? true
            }
        }
        sessions.sort { $0.lastActive > $1.lastActive }
        guard !sessions.isEmpty else {
            print(filters.isEmpty && status == nil ? "No sessions found. All tidy." : "No sessions match.")
            return
        }
        let usage = tokens ? await options.context.tokenUsageStore.usage(for: sessions, adapters: scans.map(\.adapter)) : [:]
        let rows = sessions.map { s in
            var row = [
                full ? s.id : Format.shortID(s.id),
                s.agent.isExperimental ? s.agentLabel + " *" : s.agentLabel,
                s.projectName ?? "-",
                Format.relative(s.lastActive),
                Format.bytes(s.sizeBytes),
            ]
            if tokens {
                let found = usage[s.id]?.usage
                row += [found.map { Format.tokens($0.totals.total) } ?? "-", found?.cost.map(Format.cost) ?? "-"]
            }
            return row + [Format.status(s), s.displayTitle]
        }
        var header = ["ID", "AGENT", "PROJECT", "LAST ACTIVE", "SIZE"]
        if tokens { header += ["TOKENS", "COST"] }
        print(Format.table(rows, header: header + ["STATUS", "TITLE"], rightAligned: tokens ? [4, 5, 6] : [4]))
        if sessions.contains(where: \.agent.isExperimental) {
            print("\n* \(AgentKind.experimentalNote)")
        }
        if tokens {
            let total = usage.values.compactMap(\.usage).reduce(TokenUsage(), +)
            let counted = usage.values.filter { $0.usage != nil }.count
            guard counted > 0 else {
                print("\nNone of these sessions records token usage (\"-\").")
                return
            }
            var line = "\n\(Format.tokens(total.totals.total)) tokens in \(counted) of \(sessions.count) sessions"
            if let cost = total.cost { line += ", \(Format.cost(cost)) estimated" }
            print(line + ". Costs are estimates from list prices as of \(PriceTable.asOf); \"-\" means the agent records no usage.")
        }
    }

    /// The same rows as the MCP tool `list_sessions`.
    private func printJSON(agent: AgentKind?) async throws {
        var arguments: [String: JSONValue] = ["limit": 500, "include_tokens": .bool(tokens)]
        if let agent { arguments["agent"] = .string(RuleAgentID.id(of: agent)) }
        if let project = filters.project { arguments["project"] = .string(project) }
        if let older = filters.older { arguments["older_than_days"] = .double(older.seconds / 86_400) }
        if let status { arguments["status"] = .string(status.rawValue) }
        let outcome = await DomovyTools(context: options.context).call("list_sessions", arguments: arguments)
        guard !outcome.isError else { throw Domo.fail(DomoError.message(outcome.text)) }
        PlanRunner.printJSON(outcome.structured)
    }
}

extension Session.Status: ExpressibleByArgument {}
