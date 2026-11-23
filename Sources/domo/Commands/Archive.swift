import ArgumentParser
import DomovyCore
import Foundation

struct Archive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Compress cold sessions in place so they take less disk.",
        discussion: """
        Claude Code sessions: APFS transparent compression; Claude Code reads the files unchanged and can still resume the session. \
        Modification times are kept, so Claude Code's own cleanup still applies on schedule. \
        Codex sessions: runs `codex archive` when the codex CLI is installed (Codex must be quit), else compresses in place. \
        Gemini CLI chats: APFS compression in place, like Claude Code. Antigravity is read-only for now. \
        `domo undo` reverses either.
        """
    )

    @OptionGroup var options: RootOptions

    @Argument(help: "Session id or a unique prefix of it (see `domo ls`).")
    var id: String?

    @Option(name: .long, help: "Archive every idle session last active longer ago than this (e.g. 30d, 2w).")
    var older: AgeThreshold?

    @Flag(name: .long, help: "Print the plan and change nothing.")
    var dryRun = false

    @Flag(name: [.customShort("y"), .long], help: "Skip the confirmation prompt. Required when stdin is not a terminal.")
    var yes = false

    func validate() throws {
        guard (id == nil) != (older == nil) else {
            throw ValidationError("Pass either a session id or --older <age>, not both.")
        }
    }

    func run() async throws {
        do {
            let plans: [Plan]
            if let id {
                let (adapter, session) = try await options.session(matching: id)
                let plan = try await adapter.archivePlan(for: session)
                print(Format.plan(plan))
                plans = [plan]
            } else {
                plans = try await batchPlans(await options.installedAdapters())
            }
            if dryRun {
                print("\nDry run: nothing was changed.")
                return
            }
            let runnable = plans.filter { !$0.isEmpty && !$0.liveCheck.isLive }
            guard !runnable.isEmpty else {
                if let plan = plans.first, plans.count == 1 {
                    _ = try options.executor.execute(plan) // explains why: live or nothing to do
                }
                print("\nNothing to archive.")
                return
            }
            let files = runnable.reduce(0) { $0 + $1.compressions.count }
            let commands = runnable.reduce(0) { $0 + $1.commands.count }
            let bytes = runnable.reduce(Int64(0)) { $0 + $1.totalBytes }
            if !yes {
                var what: [String] = []
                if files > 0 { what.append("compress \(files) files") }
                if commands > 0 { what.append("run codex archive \(commands) \(commands == 1 ? "time" : "times")") }
                let text = what.joined(separator: " and ")
                try confirm("\n\(text.prefix(1).uppercased() + text.dropFirst()) (\(Format.bytes(bytes))) in \(runnable.count) \(runnable.count == 1 ? "session" : "sessions")? [y/N] ")
            }
            let entries = try options.executor.execute(runnable)
            let done = entries.reduce(0) { $0 + $1.compressed.count }
            if done < files { print("\nLeft \(files - done) files as they were: they changed since planning or did not compress.") }
            let ran = commands > 0 ? " Ran codex archive for \(commands) \(commands == 1 ? "session" : "sessions")." : ""
            print("\nDone. Compressed \(done) files in \(entries.count) \(entries.count == 1 ? "session" : "sessions").\(ran) Undo with `domo undo`.")
            Domo.printLeftovers(entries)
        } catch {
            throw Domo.fail(error)
        }
    }

    /// One plan per idle, not yet archived session older than the threshold, with a short table.
    private func batchPlans(_ adapters: [any AgentAdapter]) async throws -> [Plan] {
        guard let older else { return [] }
        let cutoff = Date().addingTimeInterval(-older.seconds)
        var plans: [Plan] = []
        var rows: [[String]] = []
        // Codex sessions already in archived_sessions have nothing left to archive.
        var candidates: [(adapter: any AgentAdapter, session: Session)] = []
        // Read-only agents (Antigravity) have nothing Domovy may archive.
        for adapter in adapters where await adapter.status() == .ready {
            for session in try await adapter.sessions()
            where session.lastActive < cutoff && session.status != .live && !(session.agent == .codex && session.isArchived) {
                candidates.append((adapter, session))
            }
        }
        for (adapter, session) in candidates {
            let plan = try await adapter.archivePlan(for: session)
            plans.append(plan)
            let state = plan.liveCheck.isLive ? "blocked, skipped" : (plan.isEmpty ? "nothing to do" : (plan.commands.isEmpty ? "\(plan.compressions.count) files" : "codex archive"))
            rows.append([
                String(session.id.prefix(8)),
                session.agent.displayName,
                Format.relative(session.lastActive),
                Format.bytes(plan.totalBytes),
                plan.isEmpty || !plan.commands.isEmpty ? "-" : "~" + Format.bytes(plan.estimatedBytesAfter),
                state,
                session.displayTitle,
            ])
        }
        guard !rows.isEmpty else {
            print("No idle sessions older than \(older.text).")
            return []
        }
        print(Format.table(rows, header: ["ID", "AGENT", "LAST ACTIVE", "SIZE", "AFTER", "ACTION", "TITLE"], rightAligned: [3, 4]))
        let runnable = plans.filter { !$0.isEmpty && !$0.liveCheck.isLive }
        guard !runnable.isEmpty else { return plans }
        let compressing = runnable.filter { $0.commands.isEmpty }
        let before = compressing.reduce(Int64(0)) { $0 + $1.totalBytes }
        let after = compressing.reduce(Int64(0)) { $0 + $1.estimatedBytesAfter }
        let archiving = runnable.count - compressing.count
        if !compressing.isEmpty {
            print("\n\(compressing.count) \(compressing.count == 1 ? "session" : "sessions") compressed in place: \(Format.bytes(before)) \u{2192} ~\(Format.bytes(after)). The agent can still resume them. You can undo this.")
        }
        if archiving > 0 {
            print("\(archiving) Codex \(archiving == 1 ? "session goes" : "sessions go") to archived_sessions via `codex archive`. You can undo this.")
        }
        return plans
    }
}

/// "30d", "2w" or "12h".
struct AgeThreshold: ExpressibleByArgument {
    let seconds: TimeInterval
    let text: String

    init?(argument: String) {
        let units: [Character: TimeInterval] = ["h": 3_600, "d": 86_400, "w": 604_800]
        guard let unit = argument.last, let factor = units[unit], let value = Double(argument.dropLast()), value > 0 else { return nil }
        seconds = value * factor
        text = argument
    }
}
