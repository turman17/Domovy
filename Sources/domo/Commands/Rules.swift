import ArgumentParser
import DomovyCore
import Foundation

struct Rules: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Cleanup rules that archive or tidy sessions on their own.",
        discussion: """
        Rules live in Domovy's folder and are shared with the app, which runs the ones that are on \
        every night. `domo rules run` runs them now, for example from launchd or cron. Live \
        sessions, sessions active in the last day and read-only agents are always left alone; \
        nothing is deleted permanently, and `domo undo` reverses a run.
        """,
        subcommands: [List.self, Add.self, Remove.self, Enable.self, Disable.self, Run.self],
        defaultSubcommand: List.self
    )

    static func runner(_ options: RootOptions) -> RuleRunner {
        RuleRunner(context: DomovyContext(home: options.home, isCustomHome: options.root != nil))
    }

    /// A rule by a unique prefix of its id (8+ characters) or its preset id.
    static func rule(_ idOrPrefix: String, in rules: [CleanupRule]) throws -> CleanupRule {
        let wanted = idOrPrefix.lowercased()
        if let preset = rules.first(where: { $0.presetID == wanted }) { return preset }
        let matches = rules.filter { $0.id.uuidString.lowercased().hasPrefix(wanted) }
        guard wanted.count >= 4, matches.count == 1, let rule = matches.first else { throw RuleError.notFound(idOrPrefix) }
        return rule
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List rules, whether they are on, and their last run.")
        @OptionGroup var options: RootOptions

        func run() async throws {
            do {
                let store = Rules.runner(options).store
                let rules = try store.rules()
                let history = try store.history()
                guard !rules.isEmpty else {
                    print("No rules. Add one with `domo rules add`.")
                    return
                }
                let rows = rules.map { rule in
                    let last = history.first { $0.ruleIDs.contains(rule.id) }
                    return [
                        String(rule.id.uuidString.lowercased().prefix(8)),
                        rule.isEnabled ? "on" : "off",
                        rule.askBeforeRunning ? "asks" : "-",
                        last.map { Format.relative($0.startedAt) } ?? "never",
                        rule.title,
                    ]
                }
                print(Format.table(rows, header: ["ID", "STATE", "REVIEW", "LAST RUN", "RULE"]))
                if let last = history.first {
                    print("\nLast run \(Format.relative(last.startedAt)): \(last.summary)")
                }
            } catch {
                throw Domo.fail(error)
            }
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a rule. It stays off unless you pass --enable.",
            discussion: "Example: domo rules add --action archive --agent codex --idle-days 30 --enable"
        )
        @OptionGroup var options: RootOptions

        @Option(help: "Start from a preset: archive-idle-30, trash-idle-90, archive-before-claude-sweep.")
        var preset: String?
        @Option(help: "archive, trash or quarantine.")
        var action: String?
        @Option(name: .customLong("agent"), help: "Only this agent (repeatable), e.g. claude-code, codex.")
        var agents: [String] = []
        @Option(name: .customLong("project"), help: "Only sessions whose project path contains this text (repeatable).")
        var projects: [String] = []
        @Option(name: .customLong("status"), help: "Only sessions in this state (repeatable): idle, archived, expiring.")
        var statuses: [String] = []
        @Option(help: "Idle for at least this many days.")
        var idleDays: Int?
        @Option(help: "At least this big, e.g. 50MB.")
        var largerThan: String?
        @Option(help: "Archived for at least this many days.")
        var archivedDays: Int?
        @Option(help: "The agent's own cleanup deletes it within this many days.")
        var expiringWithin: Int?
        @Option(help: "A name for the rule.")
        var name: String?
        @Flag(help: "Turn the rule on.")
        var enable = false
        @Flag(help: "The app asks before running it (the nightly run only notifies).")
        var ask = false

        func run() async throws {
            do {
                let store = Rules.runner(options).store
                var rule: CleanupRule
                if let preset {
                    guard let base = CleanupRule.preset(preset) else { throw ValidationError("Unknown preset \(preset).") }
                    if try store.rules().contains(where: { $0.presetID == preset }) {
                        throw ValidationError("The preset \(preset) is already in your rules. Turn it on with `domo rules enable \(preset)`.")
                    }
                    rule = base
                } else {
                    guard let text = action else { throw ValidationError("Pass --action archive, trash or quarantine, or --preset.") }
                    let parsed: RuleAction
                    switch text.lowercased() {
                    case "archive": parsed = .archive
                    case "trash": parsed = .moveToTrash
                    case "quarantine": parsed = .moveToQuarantine
                    default: throw ValidationError("Unknown action \(text). Use archive, trash or quarantine.")
                    }
                    rule = CleanupRule(action: parsed, condition: RuleCondition())
                    rule.scope.agents = try agents.map { text in
                        guard let kind = RuleAgentID.parse(text) else {
                            throw ValidationError("Unknown agent \(text). Use one of: \(RuleAgentID.all.joined(separator: ", ")).")
                        }
                        return kind
                    }
                    rule.scope.projects = projects
                    rule.scope.statuses = try statuses.map { text in
                        guard let status = Session.Status(rawValue: text.lowercased()), status != .live else {
                            throw ValidationError("Unknown status \(text). Use idle, archived or expiring.")
                        }
                        return status
                    }
                    rule.condition.idleDays = idleDays
                    rule.condition.archivedDays = archivedDays
                    rule.condition.expiresWithinDays = expiringWithin
                    if let largerThan {
                        guard let bytes = RuleSize.parse(largerThan) else { throw ValidationError("Could not read the size \(largerThan). Try 50MB.") }
                        rule.condition.minimumBytes = bytes
                    }
                }
                if let name { rule.name = name }
                rule.isEnabled = enable
                rule.askBeforeRunning = ask
                if let problem = rule.validationProblem { throw RuleError.invalid(problem) }
                try store.upsert(rule)
                print("Added \(rule.id.uuidString.lowercased().prefix(8)): \(rule.title). It is \(rule.isEnabled ? "on" : "off").")
                print(rule.actionExplanation)
            } catch let error as ValidationError {
                throw error
            } catch {
                throw Domo.fail(error)
            }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a rule. Its past runs stay in the history.")
        @OptionGroup var options: RootOptions
        @Argument(help: "Rule id (a unique prefix works) or preset id.")
        var id: String

        func run() async throws {
            do {
                let store = Rules.runner(options).store
                let rule = try Rules.rule(id, in: try store.rules())
                try store.remove(rule.id)
                print("Removed: \(rule.title).")
            } catch {
                throw Domo.fail(error)
            }
        }
    }

    struct Enable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn a rule on.")
        @OptionGroup var options: RootOptions
        @Argument(help: "Rule id (a unique prefix works) or preset id.")
        var id: String

        func run() async throws { try Rules.setEnabled(true, id: id, options: options) }
    }

    struct Disable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn a rule off.")
        @OptionGroup var options: RootOptions
        @Argument(help: "Rule id (a unique prefix works) or preset id.")
        var id: String

        func run() async throws { try Rules.setEnabled(false, id: id, options: options) }
    }

    static func setEnabled(_ on: Bool, id: String, options: RootOptions) throws {
        do {
            let store = runner(options).store
            var rule = try rule(id, in: try store.rules())
            rule.isEnabled = on
            try store.upsert(rule)
            print("\(on ? "On" : "Off"): \(rule.title).")
        } catch {
            throw Domo.fail(error)
        }
    }

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run the rules that are on now.",
            discussion: """
            Rules that ask before running are planned and shown, not run, unless you name one with --rule. \
            --scheduled behaves like the app's nightly run: skipped on battery below 20% or in Low Power Mode.
            """
        )
        @OptionGroup var options: RootOptions
        @Option(help: "Only this rule (id prefix or preset id), even if it is off.")
        var rule: String?
        @Flag(help: "Print what would happen and change nothing.")
        var dryRun = false
        @Flag(help: "Run like the nightly run (for launchd): skips on low battery, records a scheduled run.")
        var scheduled = false
        @Flag(name: [.customShort("y"), .long], help: "Skip the confirmation prompt. Required when stdin is not a terminal.")
        var yes = false

        func run() async throws {
            do {
                let runner = Rules.runner(options)
                let all = try runner.store.rules()
                var chosen = all.filter(\.isEnabled)
                if let rule { chosen = [try Rules.rule(rule, in: all)] }
                guard !chosen.isEmpty else {
                    print("No rule is on. Turn one on with `domo rules enable <id>`, or pass --rule.")
                    return
                }
                let asking = rule == nil ? chosen.filter(\.askBeforeRunning) : []
                let unattended = chosen.filter { !asking.contains($0) }
                let preview = await runner.preview(unattended)
                print(Self.describe(preview))
                if !asking.isEmpty {
                    let review = await runner.preview(asking)
                    if !review.isEmpty {
                        print("\nThese rules ask first, so they do not run here (\(asking.map(\.title).joined(separator: "; "))):")
                        print(Self.describe(review))
                    }
                }
                if dryRun {
                    print("\nDry run: nothing was changed.")
                    return
                }
                if scheduled {
                    let power = PowerState.current()
                    if !yes, !preview.isEmpty, power.skipReason == nil { try confirm("\n\(preview.summary) Continue? [y/N] ") }
                    let record = try await runner.runScheduled(power: power).record
                    print("\n\(record.summary)\(record.changedAnything ? " Undo with `domo undo`." : "")")
                    return
                }
                guard !preview.isEmpty else { return }
                if !yes { try confirm("\n\(preview.summary) Continue? [y/N] ") }
                let record = await runner.run(unattended, trigger: .cli, only: preview.sessionKeys)
                print("\n\(record.summary)\(record.changedAnything ? " Undo with `domo undo`." : "")")
                let failed = record.skipped.filter { skip in preview.matches.contains { $0.session.id == skip.sessionID } }
                for skip in failed { print("  - \(skip.sessionID.map(Format.shortID) ?? skip.agent.displayName): \(skip.reason)") }
            } catch {
                throw Domo.fail(error)
            }
        }

        static func describe(_ preview: RulePreview) -> String {
            var lines: [String] = []
            if !preview.matches.isEmpty {
                let rows = preview.matches.map { match in
                    [
                        Format.shortID(match.session.id),
                        match.session.agent.displayName,
                        Format.relative(match.session.lastActive),
                        Format.bytes(match.plan.totalBytes),
                        match.rule.action == .archive ? "archive" : "to \(match.plan.destination?.rawValue ?? "trash")",
                        match.session.displayTitle,
                    ]
                }
                lines.append(Format.table(rows, header: ["ID", "AGENT", "LAST ACTIVE", "SIZE", "ACTION", "TITLE"], rightAligned: [3]))
            }
            lines.append(preview.summary)
            for skip in preview.skipped {
                lines.append("  left alone: \(skip.sessionID.map(Format.shortID) ?? skip.agent.displayName) (\(skip.agent.displayName)): \(skip.reason)")
            }
            lines += preview.notes
            return lines.joined(separator: "\n")
        }
    }
}
